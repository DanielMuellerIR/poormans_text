use serde_json::Value;
use std::{ffi::OsString, path::PathBuf};

fn locale_german(
    language: Option<&str>,
    all: Option<&str>,
    messages: Option<&str>,
    lang: Option<&str>,
) -> bool {
    language
        .filter(|s| !s.is_empty())
        .map(|s| s.split(':').next().unwrap_or(""))
        .or_else(|| all.filter(|s| !s.is_empty()))
        .or_else(|| messages.filter(|s| !s.is_empty()))
        .or(lang)
        .unwrap_or("")
        .starts_with("de")
}
pub fn german() -> bool {
    locale_german(
        std::env::var("LANGUAGE").ok().as_deref(),
        std::env::var("LC_ALL").ok().as_deref(),
        std::env::var("LC_MESSAGES").ok().as_deref(),
        std::env::var("LANG").ok().as_deref(),
    )
}

pub fn tr(de: &'static str, en: &'static str) -> &'static str {
    if german() { de } else { en }
}

#[derive(Default)]
pub struct Options {
    pub values: Vec<(String, String)>,
    pub flags: Vec<String>,
}
impl Options {
    pub fn arguments(
        &self,
        sources: &[PathBuf],
        destination: Option<&str>,
    ) -> Result<Vec<OsString>, String> {
        if sources.is_empty() {
            return Err(tr("Bitte Quellen wählen.", "Choose source documents.").into());
        }
        let mut result = Vec::new();
        for (flag, value) in &self.values {
            if !value.trim().is_empty() {
                result.push(flag.into());
                result.push(
                    if flag == "--pandoc" {
                        value.as_str()
                    } else {
                        value.trim()
                    }
                    .into(),
                );
            }
        }
        result.extend(self.flags.iter().map(OsString::from));
        if let Some(path) = destination.filter(|s| !s.trim().is_empty()) {
            result.push("--output".into());
            result.push(path.into());
        }
        result.push("--".into());
        result.extend(sources.iter().map(|p| p.as_os_str().to_owned()));
        Ok(result)
    }
}
pub type SignalHandlers =
    std::rc::Rc<std::cell::RefCell<Vec<(gtk::glib::Object, gtk::glib::SignalHandlerId)>>>;
pub fn disconnect_handlers(handlers: &SignalHandlers) {
    use gtk::prelude::ObjectExt;
    let handlers = handlers.clone();
    gtk::glib::idle_add_local_once(move || {
        for (object, id) in handlers.borrow_mut().drain(..) {
            object.disconnect(id);
        }
    });
}

#[derive(Clone, Debug)]
pub struct InputSlot {
    bound: bool,
    input: std::sync::Arc<std::sync::Mutex<Option<pmt_bridge::BoundInput>>>,
}
impl InputSlot {
    pub fn new(input: Option<pmt_bridge::BoundInput>) -> Self {
        Self {
            bound: input.is_some(),
            input: std::sync::Arc::new(std::sync::Mutex::new(input)),
        }
    }
    pub fn is_bound(&self) -> bool {
        self.bound
    }
    pub fn get(&self) -> Option<pmt_bridge::BoundInput> {
        self.input.lock().ok().and_then(|v| v.clone())
    }
    pub fn clear(&self) {
        match self.input.lock() {
            Ok(mut input) => {
                input.take();
            }
            Err(poison) => {
                poison.into_inner().take();
            }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceOrigin {
    File,
    Clipboard,
}

#[derive(Clone, Debug)]
pub struct OutputFile {
    pub bound_input: Option<pmt_bridge::BoundInput>,
    pub source_origin: SourceOrigin,
    pub label: String,
    pub path: PathBuf,
    pub preview: bool,
    pub context: Option<std::sync::Arc<crate::read_output::Context>>,
}
fn display_path(path: &str) -> String {
    let p = std::path::Path::new(path);
    let short = p
        .parent()
        .and_then(|p| p.file_name())
        .map(|parent| std::path::Path::new(parent).join(p.file_name().unwrap_or_default()))
        .unwrap_or_else(|| p.to_path_buf());
    let text = short.to_string_lossy();
    if text.chars().count() > 90 {
        format!("{}…", text.chars().take(89).collect::<String>())
    } else {
        text.into_owned()
    }
}
pub fn outputs(value: &Value) -> Vec<OutputFile> {
    let mut out = Vec::new();
    fn add(
        v: &Value,
        out: &mut Vec<OutputFile>,
        context: Option<std::sync::Arc<crate::read_output::Context>>,
    ) {
        if let Some(items) = v.get("results").and_then(Value::as_array) {
            for item in items {
                add(item, out, None);
            }
            return;
        }
        let context = context
            .unwrap_or_else(|| std::sync::Arc::new(crate::read_output::Context::new(v.clone())));
        if let Some(path) = v.get("markdownFile").and_then(Value::as_str) {
            out.push(OutputFile {
                bound_input: None,
                source_origin: SourceOrigin::File,
                label: format!("Markdown · {}", display_path(path)),
                path: path.into(),
                preview: true,
                context: Some(context.clone()),
            });
        }
        if let Some(items) = v.get("documents").and_then(Value::as_array) {
            for item in items {
                add(item, out, Some(context.clone()));
            }
        }
        if let Some(items) = v.get("assets").and_then(Value::as_array) {
            for item in items {
                if let Some(path) = item.as_str() {
                    out.push(OutputFile {
                        bound_input: None,
                        source_origin: SourceOrigin::File,
                        label: format!("Asset · {}", display_path(path)),
                        path: path.into(),
                        preview: false,
                        context: Some(context.clone()),
                    });
                }
            }
        }
    }
    add(value, &mut out, None);
    let mut seen = std::collections::HashSet::new();
    out.retain(|file| seen.insert(file.path.clone()));
    out
}

pub fn describe(value: &Value) -> String {
    fn text(v: &Value, key: &str) -> String {
        v.get(key).and_then(Value::as_str).unwrap_or("").into()
    }
    fn strings(v: &Value, key: &str) -> String {
        v.get(key)
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join(", ")
            })
            .unwrap_or_default()
    }
    let mut lines = Vec::new();
    let message = text(value, "message");
    if !message.is_empty() {
        lines.push(message);
    }
    let stderr = text(value, "stderr");
    if !stderr.is_empty() {
        lines.push(stderr);
    }
    if let Some(response) = value.get("response").filter(|v| !v.is_null()) {
        lines.push(describe(response));
    }

    if let Some(formats) = value.get("formats").and_then(Value::as_array) {
        for format in formats {
            let available = format.get("available").and_then(Value::as_bool) == Some(true);
            lines.push(format!(
                "{} (.{}): {}",
                text(format, "format").to_uppercase(),
                strings(format, "extensions").replace(", ", ", ."),
                if available {
                    tr("verfügbar", "available").into()
                } else {
                    format!(
                        "{} — {}",
                        tr("nicht verfügbar", "unavailable"),
                        text(format, "unavailableReason")
                    )
                }
            ));
            let tools = strings(format, "requires");
            if !tools.is_empty() {
                lines.push(format!("  {}: {}", tr("Benötigt", "Requires"), tools));
            }
        }
        return lines.join("\n");
    }
    if let Some(entries) = value.get("profiles").and_then(Value::as_array) {
        for entry in entries {
            lines.push(format!(
                "{} · {}",
                text(entry, "name"),
                crate::profiles::scope_label(&text(entry, "scope"))
            ));
        }
        if let Some(path) = value.get("path").and_then(Value::as_str) {
            lines.push(format!("{}: {}", tr("Gespeichert", "Saved"), path));
        }
        return lines.join("\n");
    }
    if let Some(results) = value.get("results").and_then(Value::as_array) {
        for result in results {
            lines.push(describe(result));
        }
        return lines.join("\n\n");
    }
    let input = text(value, "input");
    if !input.is_empty() {
        lines.push(input);
    }
    let error = text(value, "error");
    if !error.is_empty() {
        lines.push(format!("{}: {}", tr("Fehler", "Error"), error));
    }
    let markdown = text(value, "markdownFile");
    if !markdown.is_empty() {
        lines.push(format!(
            "{}: {}",
            tr("Markdown gespeichert", "Markdown saved"),
            markdown
        ));
    }
    let diagnostics = value.get("diagnostics").and_then(Value::as_array);
    if let Some(warnings) = value.get("warnings").and_then(Value::as_array) {
        for warning in warnings {
            let message = warning.as_str().unwrap_or("");
            if !message.is_empty()
                && !diagnostics.is_some_and(|items| {
                    items
                        .iter()
                        .any(|item| item.get("message").and_then(Value::as_str) == Some(message))
                })
            {
                lines.push(message.into());
            }
        }
    }
    if let Some(items) = diagnostics {
        for item in items {
            let message = text(item, "message");
            if message.is_empty() {
                continue;
            }
            let mut context = Vec::new();
            if let Some(location) = item.get("location") {
                for (key, name) in [
                    ("page", tr("Seite", "page")),
                    ("sheet", tr("Blatt", "sheet")),
                    ("sheetIndex", tr("Blattindex", "sheet index")),
                    ("cell", tr("Zelle", "cell")),
                    ("chapter", tr("Kapitel", "chapter")),
                    ("slide", tr("Folie", "slide")),
                    ("frame", tr("Bild", "frame")),
                    ("paragraph", tr("Absatz", "paragraph")),
                    ("message", tr("Nachricht", "message")),
                    ("note", tr("Notiz", "note")),
                ] {
                    if let Some(value) = location.get(key).filter(|v| !v.is_null()) {
                        let value = value
                            .as_str()
                            .map(str::to_owned)
                            .unwrap_or_else(|| value.to_string());
                        context.push(format!("{name} {value}"));
                    }
                }
            }
            lines.push(if context.is_empty() {
                message
            } else {
                format!("{} ({})", message, context.join(", "))
            });
        }
    }
    for key in ["sheets", "slides", "chapters"] {
        if let Some(items) = value.get(key).and_then(Value::as_array) {
            for item in items {
                let number = item
                    .get("index")
                    .or_else(|| item.get("number"))
                    .map(ToString::to_string)
                    .unwrap_or_default();
                let title = item
                    .get("name")
                    .or_else(|| item.get("title"))
                    .and_then(Value::as_str)
                    .unwrap_or("");
                let mut detail = Vec::new();
                if let Some(visibility) = item.get("visibility").and_then(Value::as_str) {
                    detail.push(visibility.to_string());
                }
                if item.get("isReadable").and_then(Value::as_bool) == Some(false) {
                    detail.push(tr("nicht lesbar", "unreadable").into());
                }
                if let Some(notes) = item.get("hasNotes").and_then(Value::as_bool) {
                    detail.push(
                        if notes {
                            tr("mit Notizen", "with notes")
                        } else {
                            tr("ohne Notizen", "without notes")
                        }
                        .into(),
                    );
                }
                if let Some(linear) = item.get("isLinear").and_then(Value::as_bool) {
                    detail.push(
                        if linear {
                            tr("Hauptlesefolge", "primary reading order")
                        } else {
                            tr("Zusatzkapitel", "auxiliary chapter")
                        }
                        .into(),
                    );
                }
                lines.push(format!(
                    "{} · {}{}",
                    number,
                    title,
                    if detail.is_empty() {
                        String::new()
                    } else {
                        format!(" ({})", detail.join(", "))
                    }
                ));
            }
        }
    }
    for key in ["sheetsTruncated", "slidesTruncated", "chaptersTruncated"] {
        if value.get(key).and_then(Value::as_bool) == Some(true) {
            lines.push(
                tr(
                    "Die Inhaltsübersicht ist begrenzt; weitere Einträge sind nicht angezeigt.",
                    "The content overview is limited; further entries are not shown.",
                )
                .into(),
            );
        }
    }
    if lines.is_empty() {
        lines.push(tr("Keine weiteren Hinweise.", "No additional information.").into());
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn arguments_preserve_paths_and_separator() {
        let options = Options {
            values: vec![("--sheets".into(), "1,3".into())],
            flags: vec!["--report".into()],
        };
        let args = options
            .arguments(&[PathBuf::from("/tmp/-é\n.csv")], Some("/tmp/new output "))
            .unwrap();
        assert_eq!(
            args,
            vec![
                "--sheets",
                "1,3",
                "--report",
                "--output",
                "/tmp/new output ",
                "--",
                "/tmp/-é\n.csv"
            ]
            .into_iter()
            .map(OsString::from)
            .collect::<Vec<_>>()
        );
    }
    #[test]
    fn empty_input_is_error() {
        assert!(Options::default().arguments(&[], None).is_err());
    }
    #[test]
    fn partial_result_retains_only_declared_files() {
        let value = serde_json::json!({"results":[{"ok":true,"markdownFile":"/tmp/a.md","assets":["/tmp/a.png"]},{"ok":false,"error":"failed"}]});
        let files = outputs(&value);
        assert_eq!(files.len(), 2);
        assert!(files[0].preview);
        assert!(!files[1].preview);
    }
    #[test]
    fn physical_unicode_output_paths_remain_distinct() {
        let value = serde_json::json!({"results":[{"markdownFile":"/tmp/é.md"},{"markdownFile":"/tmp/e\u{301}.md"}]});
        assert_eq!(outputs(&value).len(), 2);
    }
    #[test]
    fn language_overrides_c_locale() {
        assert!(locale_german(
            Some("de:en"),
            Some("C.UTF-8"),
            None,
            Some("en_US.UTF-8")
        ));
        assert!(!locale_german(
            None,
            Some("C.UTF-8"),
            None,
            Some("de_DE.UTF-8")
        ));
    }
    #[test]
    fn catalog_and_diagnostics_are_readable() {
        let catalog = serde_json::json!({"formats":[{"format":"docx","extensions":["docx"],"available":false,"requires":["pandoc"],"unavailableReason":"Pandoc missing"}]});
        let text = describe(&catalog);
        assert!(text.contains("DOCX (.docx)"));
        assert!(text.contains("Pandoc missing"));
        assert!(!text.contains("unavailableReason"));
        let failed = serde_json::json!({"results":[{"input":"/tmp/a.csv","error":"Broken rows"},{"warnings":["Image missing"]}]});
        let text = describe(&failed);
        assert!(text.contains("Broken rows"));
        assert!(text.contains("Image missing"));
    }
    #[test]
    fn diagnostics_keep_each_provided_location() {
        let value = serde_json::json!({"warnings":["Data missing"],"diagnostics":[{"message":"Data missing","location":{"cell":"A1","sheetIndex":1}},{"message":"Data missing","location":{"cell":"B2","sheetIndex":2}}]});
        let text = describe(&value);
        assert!(text.contains("A1"));
        assert!(text.contains("B2"));
        assert_eq!(text.matches("Data missing").count(), 2);
    }
}
