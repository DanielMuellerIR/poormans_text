use crate::{
    View,
    model::{FlagOption, ValueOption, tr},
};
use gtk::{gio, glib, prelude::*};
use std::{collections::BTreeMap, path::Path};

const ID: &str = "org.poormanstext.Linux";
// Nur allgemeine Optionen: Quellauswahl, Pfade und Profilfreigaben bleiben sitzungsgebunden.
const VALUES: &[(ValueOption, &str)] = &[
    (ValueOption::OcrLanguage, "ocr-language"),
    (ValueOption::Jobs, "jobs"),
    (ValueOption::Timeout, "timeout"),
];
const CHOICES: &[(ValueOption, &str)] = &[
    (ValueOption::OcrMethod, "ocr-method"),
    (ValueOption::SpreadsheetFormat, "spreadsheet-format"),
    (ValueOption::ImageOcr, "image-ocr"),
    (ValueOption::PdfOcr, "pdf-ocr"),
    (ValueOption::PdfLayout, "pdf-layout"),
    (ValueOption::DocxChanges, "docx-changes"),
    (ValueOption::Notes, "notes"),
];
const FLAGS: &[(FlagOption, &str)] = &[
    (FlagOption::Frontmatter, "frontmatter"),
    (FlagOption::TextBundle, "textbundle"),
    (FlagOption::Report, "report"),
    (FlagOption::SourceMap, "source-map"),
    (
        FlagOption::PdfRemoveHeadersFooters,
        "pdf-remove-headers-footers",
    ),
    (FlagOption::PdfDehyphenate, "pdf-dehyphenate"),
];

fn valid_text(key: ValueOption, text: &str) -> bool {
    if text.len() > 256 {
        return false;
    }
    text.bytes().all(|b| match key {
        ValueOption::OcrLanguage => b.is_ascii_alphanumeric() || b",-_ ".contains(&b),
        ValueOption::Jobs | ValueOption::Timeout => b.is_ascii_digit() || b == b'.',
        _ => false,
    })
}
fn load_schema(directory: &Path) -> Result<gio::SettingsSchema, String> {
    let source = gio::SettingsSchemaSource::from_directory(directory, None, false)
        .map_err(|e| e.to_string())?;
    let schema = source.lookup(ID, false).ok_or(tr(
        "Das mitgelieferte Einstellungsschema fehlt.",
        "The bundled preferences schema is missing.",
    ))?;
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
        return Err(tr(
            "Das mitgelieferte Einstellungsschema ist inkompatibel.",
            "The bundled preferences schema is incompatible.",
        )
        .into());
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
                        .ok_or(tr(
                            "Das Verzeichnis der Programmdatei fehlt.",
                            "The executable directory is missing.",
                        ))?
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
            for &(option, key) in VALUES {
                let value = settings.string(key);
                if valid_text(option, &value) {
                    view.controls.value(option).set_text(&value);
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
            for &(option, key) in CHOICES {
                if !view.controls.choice(option).select(&settings.string(key)) {
                    warning(
                        notice,
                        tr(
                            "Eine nicht unterstützte Auswahl wurde ignoriert.",
                            "An unsupported choice was ignored.",
                        ),
                    );
                }
            }
            for &(option, key) in FLAGS {
                view.controls.flag(option).set_active(settings.boolean(key));
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
    for &(option, key) in VALUES {
        let value = view.controls.value(option).text();
        if valid_text(option, &value) {
            result.insert(key.into(), value.to_variant());
        }
    }
    for &(option, key) in CHOICES {
        if let Some(value) = view.controls.choice(option).selected() {
            result.insert(key.into(), value.to_variant());
        }
    }
    for &(option, key) in FLAGS {
        result.insert(
            key.into(),
            view.controls.flag(option).is_active().to_variant(),
        );
    }
    result
}

#[cfg(feature = "ui-self-test")]
mod probe;
#[cfg(feature = "ui-self-test")]
pub use probe::probe;

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
                    .map(|(option, _)| option.cli_flag())
                    .chain(FLAGS.iter().map(|(option, _)| option.cli_flag()))
                    .any(|flag| flag == prohibited)
            );
        }
        assert!(!valid_text(ValueOption::OcrLanguage, "/home/private"));
        assert!(!valid_text(ValueOption::PdfPages, "1\n--output"));
        assert!(!valid_text(ValueOption::CellRange, &"A".repeat(257)));
        assert!(valid_text(ValueOption::OcrLanguage, "de,en-US"));
        assert!(!valid_text(ValueOption::PdfPages, "1,3-5"));
        assert!(!valid_text(ValueOption::Sheets, "visible"));
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
                .map(|(_, key)| *key)
                .chain(FLAGS.iter().map(|(_, key)| *key)),
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
