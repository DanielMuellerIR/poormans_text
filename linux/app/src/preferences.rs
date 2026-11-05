use crate::{View, model::tr};
use gtk::{gio, glib, prelude::*};
use std::{collections::BTreeMap, path::Path};

const ID: &str = "org.poormanstext.Linux";
// Nur allgemeine Optionen: Quellauswahl, Pfade und Profilfreigaben bleiben sitzungsgebunden.
const VALUES: &[(&str, &str)] = &[
    ("--ocr-language", "ocr-language"),
    ("--jobs", "jobs"),
    ("--timeout", "timeout"),
];
const CHOICES: &[(&str, &str)] = &[
    ("--ocr-method", "ocr-method"),
    ("--spreadsheet-format", "spreadsheet-format"),
    ("--image-ocr", "image-ocr"),
    ("--pdf-ocr", "pdf-ocr"),
    ("--pdf-layout", "pdf-layout"),
    ("--docx-changes", "docx-changes"),
    ("--notes", "notes"),
];
const FLAGS: &[(&str, &str)] = &[
    ("--frontmatter", "frontmatter"),
    ("--textbundle", "textbundle"),
    ("--report", "report"),
    ("--source-map", "source-map"),
    ("--pdf-remove-headers-footers", "pdf-remove-headers-footers"),
    ("--pdf-dehyphenate", "pdf-dehyphenate"),
];

fn valid_text(key: &str, text: &str) -> bool {
    if text.len() > 256 {
        return false;
    }
    text.bytes().all(|b| match key {
        "ocr-language" => b.is_ascii_alphanumeric() || b",-_ ".contains(&b),
        "jobs" | "timeout" => b.is_ascii_digit() || b == b'.',
        _ => false,
    })
}
fn load_schema(directory: &Path) -> Result<gio::SettingsSchema, String> {
    let source = gio::SettingsSchemaSource::from_directory(directory, None, false)
        .map_err(|e| e.to_string())?;
    let schema = source
        .lookup(ID, false)
        .ok_or("The bundled preferences schema is missing")?;
    let mut expected = vec![
        ("window-width", "i"),
        ("window-height", "i"),
        ("window-maximized", "b"),
        ("options-tab", "i"),
    ];
    expected.extend(VALUES.iter().chain(CHOICES).map(|(_, key)| (*key, "s")));
    expected.extend(FLAGS.iter().map(|(_, key)| (*key, "b")));
    if schema.path().as_deref() != Some("/org/poormanstext/Linux/")
        || schema.list_keys().len() != expected.len()
        || expected
            .iter()
            .any(|(key, ty)| !schema.has_key(key) || schema.key(key).value_type().as_str() != *ty)
    {
        return Err("The bundled preferences schema is incompatible".into());
    }
    Ok(schema)
}
fn warning(label: &gtk::Label, detail: &str) {
    label.set_text(&format!(
        "{} {detail}",
        tr(
            "Einstellungen können nicht vollständig wiederhergestellt oder gespeichert werden.",
            "Preferences could not be fully restored or saved."
        )
    ));
    label.set_visible(true);
}

pub struct Session {
    settings: Option<gio::Settings>,
    initial: BTreeMap<String, glib::Variant>,
    notice: gtk::Label,
}
impl Session {
    pub fn restore(view: &View, notice: &gtk::Label) -> Self {
        let loaded = std::env::current_exe()
            .map_err(|e| e.to_string())
            .and_then(|exe| {
                load_schema(
                    &exe.parent()
                        .ok_or("Missing executable directory")?
                        .join("schemas"),
                )
            });
        let settings = match loaded {
            Ok(schema) => Some(gio::Settings::new_full(
                &schema,
                None::<&gio::SettingsBackend>,
                None,
            )),
            Err(error) => {
                warning(notice, &error);
                None
            }
        };
        if let Some(settings) = &settings {
            if settings
                .backend()
                .is_none_or(|backend| backend.type_().name() == "GMemorySettingsBackend")
            {
                warning(
                    notice,
                    tr(
                        "Der Einstellungsspeicher ist nur temporär; Änderungen bleiben nach dem Beenden nicht erhalten.",
                        "The preferences backend is temporary; changes will not survive quitting.",
                    ),
                );
            }
            view.window
                .set_default_size(settings.int("window-width"), settings.int("window-height"));
            if settings.boolean("window-maximized") {
                view.window.maximize();
            }
            view.options
                .set_current_page(Some(settings.int("options-tab").clamp(0, 3) as u32));
            for (flag, key) in VALUES {
                let value = settings.string(key);
                if valid_text(key, &value) {
                    if let Some((_, entry)) = view.controls.values.iter().find(|(f, _)| f == flag) {
                        entry.set_text(&value);
                    }
                } else {
                    warning(
                        notice,
                        tr(
                            "Eine ungültige Option wurde ignoriert.",
                            "An invalid option was ignored.",
                        ),
                    );
                }
            }
            for (flag, key) in CHOICES {
                if let Some((_, widget, ids)) =
                    view.controls.choices.iter().find(|(f, _, _)| f == flag)
                {
                    let value = settings.string(key);
                    if let Some(index) = ids.iter().position(|id| id == value.as_str()) {
                        widget.set_selected(index as u32);
                    } else {
                        warning(
                            notice,
                            tr(
                                "Eine nicht unterstützte Auswahl wurde ignoriert.",
                                "An unsupported choice was ignored.",
                            ),
                        );
                    }
                }
            }
            for (flag, key) in FLAGS {
                if let Some((_, widget)) = view.controls.flags.iter().find(|(f, _)| f == flag) {
                    widget.set_active(settings.boolean(key));
                }
            }
        }
        let initial = snapshot(view);
        if let Some(settings) = &settings
            && initial.keys().any(|key| !settings.is_writable(key))
        {
            warning(
                notice,
                tr(
                    "Der Einstellungsspeicher ist schreibgeschützt.",
                    "The preferences backend is read-only.",
                ),
            );
        }
        Self {
            settings,
            initial,
            notice: notice.clone(),
        }
    }

    pub fn save(&self, view: &View) {
        let Some(settings) = &self.settings else {
            return;
        };
        let current = snapshot(view);
        let changed: Vec<_> = current
            .iter()
            .filter(|(key, value)| self.initial.get(*key) != Some(*value))
            .collect();
        if changed.is_empty() {
            return;
        }
        if changed.iter().any(|(key, _)| !settings.is_writable(key)) {
            warning(
                &self.notice,
                tr(
                    "Der Einstellungsspeicher ist schreibgeschützt.",
                    "The preferences backend is read-only.",
                ),
            );
            return;
        }
        // Ein gemeinsamer Backend-Commit; bloßes Öffnen/Rendern schreibt nichts.
        settings.delay();
        for (key, value) in changed {
            if let Err(error) = settings.set_value(key, value) {
                settings.revert();
                warning(&self.notice, &error.to_string());
                return;
            }
        }
        settings.apply();
        gio::Settings::sync();
    }
}

fn snapshot(view: &View) -> BTreeMap<String, glib::Variant> {
    let mut result = BTreeMap::new();
    result.insert(
        "window-width".into(),
        view.window.default_width().clamp(700, 3200).to_variant(),
    );
    result.insert(
        "window-height".into(),
        view.window.default_height().clamp(600, 2400).to_variant(),
    );
    result.insert(
        "window-maximized".into(),
        view.window.is_maximized().to_variant(),
    );
    result.insert(
        "options-tab".into(),
        (view.options.current_page().unwrap_or(0).min(3) as i32).to_variant(),
    );
    for (flag, key) in VALUES {
        if let Some((_, widget)) = view.controls.values.iter().find(|(f, _)| f == flag) {
            let value = widget.text();
            if valid_text(key, &value) {
                result.insert((*key).into(), value.to_variant());
            }
        }
    }
    for (flag, key) in CHOICES {
        if let Some((_, widget, ids)) = view.controls.choices.iter().find(|(f, _, _)| f == flag)
            && let Some(value) = ids.get(widget.selected() as usize)
        {
            result.insert((*key).into(), value.to_variant());
        }
    }
    for (flag, key) in FLAGS {
        if let Some((_, widget)) = view.controls.flags.iter().find(|(f, _)| f == flag) {
            result.insert((*key).into(), widget.is_active().to_variant());
        }
    }
    result
}

#[cfg(feature = "ui-self-test")]
pub fn probe(state: &crate::Shared, view: &View) {
    let Ok(mode) = std::env::var("PMT_UI_TEST_PREFERENCES") else {
        return;
    };
    let state = state.clone();
    let view = view.clone();
    glib::timeout_add_local(std::time::Duration::from_millis(300), move || {
        if state.borrow().is_busy() {
            return glib::ControlFlow::Continue;
        }
        assert!(view.window.is_visible());
        match mode.as_str() {
            "write" => {
                view.window.set_default_size(1180, 920);
                view.options.set_current_page(Some(2));
                view.controls
                    .values
                    .iter()
                    .find(|(f, _)| f == "--ocr-language")
                    .unwrap()
                    .1
                    .set_text("de,en");
                view.controls
                    .flags
                    .iter()
                    .find(|(f, _)| f == "--report")
                    .unwrap()
                    .1
                    .set_active(true);
                view.controls
                    .choices
                    .iter()
                    .find(|(f, _, _)| f == "--pdf-ocr")
                    .unwrap()
                    .1
                    .set_selected(1);
                view.destination.set_text("/private/never-persist-target");
                view.controls
                    .values
                    .iter()
                    .find(|(f, _)| f == "--pandoc")
                    .unwrap()
                    .1
                    .set_text("/private/never-persist-tool");
                state.borrow_mut().profile.allow_local = true;
            }
            "read" => {
                assert_eq!(
                    (view.window.default_width(), view.window.default_height()),
                    (1180, 920)
                );
                assert_eq!(view.options.current_page(), Some(2));
                assert_eq!(
                    view.controls
                        .values
                        .iter()
                        .find(|(f, _)| f == "--ocr-language")
                        .unwrap()
                        .1
                        .text(),
                    "de,en"
                );
                assert!(
                    view.controls
                        .flags
                        .iter()
                        .find(|(f, _)| f == "--report")
                        .unwrap()
                        .1
                        .is_active()
                );
                assert_eq!(
                    view.controls
                        .choices
                        .iter()
                        .find(|(f, _, _)| f == "--pdf-ocr")
                        .unwrap()
                        .1
                        .selected(),
                    1
                );
                assert!(state.borrow().sources.is_empty());
                assert!(view.destination.text().is_empty());
                assert!(
                    view.controls
                        .values
                        .iter()
                        .find(|(f, _)| f == "--pandoc")
                        .unwrap()
                        .1
                        .text()
                        .is_empty()
                );
                assert!(!state.borrow().profile.allow_local);
                assert!(state.borrow().profile.name.is_none());
            }
            "missing" => {
                fn warned(widget: &gtk::Widget) -> bool {
                    if let Some(label) = widget.downcast_ref::<gtk::Label>()
                        && label.is_visible()
                        && label.label().contains("Preferences could not")
                    {
                        return true;
                    }
                    let mut child = widget.first_child();
                    while let Some(widget) = child {
                        if warned(&widget) {
                            return true;
                        }
                        child = widget.next_sibling();
                    }
                    false
                }
                assert!(warned(view.window.upcast_ref()));
            }
            "unchanged" => {}
            _ => panic!("Unknown private preferences probe"),
        }
        eprintln!("PMT_UI_TEST_PREFERENCES {mode} passed");
        let window = view.window.clone();
        glib::timeout_add_local_once(std::time::Duration::from_millis(400), move || {
            window.close()
        });
        glib::ControlFlow::Break
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn whitelist_excludes_paths_and_profile_permissions() {
        for prohibited in [
            "--pandoc",
            "--output",
            "--profile",
            "--profile-local",
            "--profiles-directory",
            "--clear-profile-selection",
            "--pdf-pages",
            "--epub-chapters",
            "--sheets",
            "--cell-range",
            "--slides",
        ] {
            assert!(
                !VALUES
                    .iter()
                    .chain(CHOICES)
                    .chain(FLAGS)
                    .any(|(flag, _)| *flag == prohibited)
            );
        }
        assert!(!valid_text("ocr-language", "/home/private"));
        assert!(!valid_text("pdf-pages", "1\n--output"));
        assert!(!valid_text("cell-range", &"A".repeat(257)));
        assert!(valid_text("ocr-language", "de,en-US"));
        assert!(!valid_text("pdf-pages", "1,3-5"));
        assert!(!valid_text("sheets", "visible"));
    }
    #[test]
    fn missing_schema_is_a_recoverable_error() {
        assert!(load_schema(Path::new("/nonexistent/pmt-preferences-schema")).is_err());
    }
    #[test]
    fn schema_has_exactly_the_allowed_preferences() {
        let directory = std::env::temp_dir().join(format!(
            "pmt-preferences-schema-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&directory).unwrap();
        assert!(
            std::process::Command::new("glib-compile-schemas")
                .arg("--strict")
                .arg(format!("--targetdir={}", directory.display()))
                .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("schemas"))
                .status()
                .unwrap()
                .success()
        );
        let schema = load_schema(&directory).unwrap();
        let mut expected = vec![
            "window-width",
            "window-height",
            "window-maximized",
            "options-tab",
        ];
        expected.extend(
            VALUES
                .iter()
                .chain(CHOICES)
                .chain(FLAGS)
                .map(|(_, key)| *key),
        );
        expected.sort();
        let mut actual: Vec<_> = schema.list_keys().iter().map(|v| v.to_string()).collect();
        actual.sort();
        assert_eq!(actual, expected);
        let memory = gio::memory_settings_backend_new();
        let settings = gio::Settings::new_full(&schema, Some(&memory), None);
        assert!(settings.set_int("window-width", 3).is_err());
        assert!(settings.set_string("pdf-ocr", "structured").is_err());
        assert_eq!(settings.int("window-width"), 1060);
        assert!(settings.boolean("source-map"));
        assert_eq!(settings.string("jobs"), "");
        assert_eq!(settings.string("ocr-method"), "standard");
        assert!(settings.set_string("ocr-method", "structured").is_ok());
        assert!(settings.set_string("ocr-method", "remote").is_err());
        assert!(settings.set_string("pdf-ocr", "off").is_ok());
        assert_eq!(settings.string("pdf-ocr"), "off");
        std::fs::remove_file(directory.join("gschemas.compiled")).unwrap();
        let broken = directory.join("incompatible.gschema.xml");
        std::fs::write(&broken, r#"<schemalist><schema id="org.poormanstext.Linux" path="/org/poormanstext/Linux/"><key name="window-width" type="s"><default>''</default></key></schema></schemalist>"#).unwrap();
        assert!(
            std::process::Command::new("glib-compile-schemas")
                .arg("--strict")
                .arg(&directory)
                .status()
                .unwrap()
                .success()
        );
        assert!(load_schema(&directory).is_err());
        std::fs::remove_file(directory.join("gschemas.compiled")).unwrap();
        std::fs::remove_file(broken).unwrap();
        std::fs::remove_dir(directory).unwrap();
    }
}
