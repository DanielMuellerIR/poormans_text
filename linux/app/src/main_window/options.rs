use super::{
    dialogs::{dialog_error, reject_remote, ticket_current},
    widgets::{label, row},
};
use crate::{
    Shared, View,
    model::{FlagOption, Options, ValueOption, tr},
};
use gtk::{gio, prelude::*};

#[derive(Clone, Default)]
pub(crate) struct Controls {
    values: Vec<(ValueOption, gtk::Entry)>,
    choices: Vec<(ValueOption, Choice)>,
    flags: Vec<(FlagOption, gtk::CheckButton)>,
}

#[derive(Clone)]
pub(crate) struct Choice {
    widget: gtk::DropDown,
    ids: Vec<&'static str>,
}

impl Choice {
    pub(crate) fn select(&self, id: &str) -> bool {
        let Some(index) = self.ids.iter().position(|known| *known == id) else {
            return false;
        };
        self.widget.set_selected(index as u32);
        true
    }

    pub(crate) fn selected(&self) -> Option<&'static str> {
        self.ids.get(self.widget.selected() as usize).copied()
    }
}

impl Controls {
    pub(crate) fn value(&self, key: ValueOption) -> &gtk::Entry {
        self.values
            .iter()
            .find(|(registered, _)| *registered == key)
            .map(|(_, widget)| widget)
            .expect("missing entry for conversion option")
    }

    pub(crate) fn choice(&self, key: ValueOption) -> &Choice {
        self.choices
            .iter()
            .find(|(registered, _)| *registered == key)
            .map(|(_, choice)| choice)
            .expect("missing dropdown for conversion option")
    }

    pub(crate) fn flag(&self, key: FlagOption) -> &gtk::CheckButton {
        self.flags
            .iter()
            .find(|(registered, _)| *registered == key)
            .map(|(_, widget)| widget)
            .expect("missing checkbox for conversion option")
    }

    fn check_value_registration(&self, key: ValueOption) {
        assert!(
            !self.values.iter().any(|(registered, _)| *registered == key)
                && !self
                    .choices
                    .iter()
                    .any(|(registered, _)| *registered == key),
            "duplicate conversion option: {key:?}"
        );
    }

    fn register_flag(&mut self, key: FlagOption, widget: gtk::CheckButton) {
        assert!(
            !self.flags.iter().any(|(registered, _)| *registered == key),
            "duplicate conversion flag: {key:?}"
        );
        self.flags.push((key, widget));
    }

    pub(crate) fn set_profile_mode(&self, active: bool) {
        for (key, widget) in &self.values {
            widget.set_sensitive(!active || key.is_execution_control());
        }
        for (_, choice) in &self.choices {
            choice.widget.set_sensitive(!active);
        }
        for (_, widget) in &self.flags {
            widget.set_sensitive(!active);
        }
    }

    pub(super) fn execution_options(&self) -> Options {
        Options {
            values: self
                .values
                .iter()
                .filter(|(key, _)| key.is_execution_control())
                .map(|(key, entry)| (*key, entry.text().to_string()))
                .collect(),
            ..Options::default()
        }
    }

    pub(crate) fn snapshot(&self) -> Options {
        let mut values: Vec<_> = self
            .values
            .iter()
            .map(|(key, widget)| (*key, widget.text().to_string()))
            .collect();
        // --notes on aktiviert bereits eine Präsentationsauswahl. Unveränderte
        // Auswahlen bleiben weg, damit die CLI beispielsweise CSV annehmen kann.
        values.extend(self.choices.iter().filter_map(|(key, choice)| {
            let index = choice.widget.selected();
            if index == 0 {
                return None;
            }
            choice
                .ids
                .get(index as usize)
                .map(|id| (*key, (*id).into()))
        }));
        Options {
            values,
            flags: self
                .flags
                .iter()
                .filter(|(_, widget)| widget.is_active())
                .map(|(key, _)| *key)
                .collect(),
        }
    }
}

pub(super) struct OptionsSection {
    pub tabs: gtk::Notebook,
    pub controls: Controls,
    pub destination: gtk::Entry,
    pub pandoc_entry: gtk::Entry,
    pub inspect: gtk::Button,
    pub inspect_kind: gtk::DropDown,
    choose_destination: gtk::Button,
}

pub(super) fn build(outer: &gtk::Box) -> OptionsSection {
    let tabs = gtk::Notebook::new();
    let mut controls = Controls::default();
    let (destination, choose_destination) = output_page(&tabs, &mut controls);
    ocr_page(&tabs, &mut controls);
    let (inspect, inspect_kind) = selection_page(&tabs, &mut controls);
    let pandoc_entry = execution_page(&tabs, &mut controls);
    outer.append(&tabs);
    OptionsSection {
        tabs,
        controls,
        destination,
        pandoc_entry,
        inspect,
        inspect_kind,
        choose_destination,
    }
}

fn output_page(notebook: &gtk::Notebook, controls: &mut Controls) -> (gtk::Entry, gtk::Button) {
    let output = page(notebook, tr("Ausgabe", "Output"));
    let destination = gtk::Entry::builder()
        .placeholder_text(tr(
            "Leer: neben jeder Quelle; sonst neuer Ausgabeordner",
            "Empty: beside each source; otherwise a new output folder",
        ))
        .build();
    destination.set_tooltip_text(Some(tr(
        "Pfad zu einem neuen Ausgabeordner. Leer speichert das Ergebnis neben der jeweiligen Quelle.",
        "Path to a new output folder. Leave empty to save the result beside each source.",
    )));
    let destination_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    destination.set_hexpand(true);
    destination_row.append(&destination);
    let choose_destination = gtk::Button::with_label(tr("Ziel wählen…", "Choose target…"));
    choose_destination.set_tooltip_text(Some(tr(
        "Öffnet den Dialog zur Wahl des neuen Ausgabeordners.",
        "Opens the dialog for choosing the new output folder.",
    )));
    destination_row.append(&choose_destination);
    output.append(&destination_row);
    output.append(&label(tr("Vorhandene Ergebnisordner werden niemals überschrieben. Bei mehreren Quellen dient das Ziel als neuer Sammelordner.","Existing result folders are never overwritten. For multiple sources the target is a new parent folder.")));
    choice(
        &output,
        tr("Tabellen", "Tables"),
        ValueOption::SpreadsheetFormat,
        &[("table", "Markdown"), ("tsv", "TSV")],
        tr(
            "Markdown erzeugt eine lesbare Tabelle. TSV trennt Zellen durch Tabulatoren und eignet sich zum Weiterverarbeiten in Tabellenprogrammen.",
            "Markdown creates a readable table. TSV separates cells with tabs for use in spreadsheet tools.",
        ),
        controls,
    );
    let output_flags = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .homogeneous(false)
        .min_children_per_line(1)
        .max_children_per_line(4)
        .column_spacing(16)
        .row_spacing(8)
        .build();
    output.append(&output_flags);
    for (name, key, default, help) in [
        (
            tr("YAML-Metadaten", "YAML frontmatter"),
            FlagOption::Frontmatter,
            false,
            tr(
                "Schreibt Angaben aus der Quelle, etwa Titel, Autor oder Datum, in einen Block am Anfang der Markdown-Datei. Die Zeile --- öffnet und schließt den Block. Programme können diese Angaben getrennt vom Text lesen.",
                "Writes details such as the title, author or date in a block at the top of the Markdown file. A line of three dashes (---) opens and closes the block. Other tools can read these details separately from the text.",
            ),
        ),
        (
            "TextBundle",
            FlagOption::TextBundle,
            false,
            tr(
                "Verpackt Markdown und Bilder gemeinsam in einem .textbundle-Ordner für Programme wie iA Writer.",
                "Packages Markdown and images in one .textbundle folder for apps such as iA Writer.",
            ),
        ),
        (
            tr("Konvertierungsbericht", "Conversion report"),
            FlagOption::Report,
            false,
            tr(
                "Speichert neben dem Markdown eine JSON-Datei mit Informationen zur Konvertierung, verwendeten Werkzeugen und Warnungen.",
                "Saves a JSON file alongside the Markdown with conversion details, tools used and warnings.",
            ),
        ),
        (
            tr("Quellzuordnung", "Source mapping"),
            FlagOption::SourceMap,
            true,
            tr(
                "Ordnet Markdown-Abschnitte nach Möglichkeit ihren Fundstellen in der Quelle zu, etwa PDF-Seiten. Das hilft beim Quellvergleich.",
                "Links Markdown sections to their locations in the source, such as PDF pages, when possible. This helps when comparing the output with the source.",
            ),
        ),
    ] {
        let checkbox = gtk::CheckButton::with_label(name);
        checkbox.set_active(default);
        checkbox.set_tooltip_text(Some(help));
        output_flags.append(&checkbox);
        controls.register_flag(key, checkbox);
    }
    (destination, choose_destination)
}

fn ocr_page(notebook: &gtk::Notebook, controls: &mut Controls) {
    let ocr = page(notebook, "OCR / PDF");
    choice(
        &ocr,
        tr("Bild-OCR", "Image OCR"),
        ValueOption::ImageOcr,
        &[("on", tr("Ein", "On")), ("off", tr("Aus", "Off"))],
        tr(
            "Erkennt Schrift in Bildern und fügt den erkannten Text zur Ausgabe hinzu.",
            "Recognizes writing in images and adds the recognized text to the output.",
        ),
        controls,
    );
    choice(
        &ocr,
        "PDF OCR",
        ValueOption::PdfOcr,
        &[
            ("auto", tr("Automatisch", "Automatic")),
            ("off", tr("Aus", "Off")),
            ("always", tr("Immer", "Always")),
        ],
        tr(
            "Automatisch erkennt Text auf Seiten ohne brauchbare Textebene. Immer prüft auch Seiten mit eingebettetem Text. Aus verwendet die vorhandene Textebene.",
            "Automatic recognizes text on pages without usable embedded text. Always also checks pages with embedded text. Off uses the existing text layer.",
        ),
        controls,
    );
    choice(
        &ocr,
        tr("OCR-Methode", "OCR method"),
        ValueOption::OcrMethod,
        &[
            ("standard", tr("Standard (lokal)", "Standard (local)")),
            (
                "structured",
                tr(
                    "Strukturiert (optionale lokale Modelle)",
                    "Structured (optional local models)",
                ),
            ),
        ],
        tr(
            "Standard erkennt Text. Strukturiert versucht zusätzlich, Absätze, Listen und Tabellen zu erhalten, und benötigt ein optionales lokales Modell.",
            "Standard recognizes text. Structured also tries to preserve paragraphs, lists and tables, using an optional local model.",
        ),
        controls,
    );
    ocr.append(&label(tr("Strukturierte OCR benötigt eine separat geprüfte lokale Modellruntime. Text und Tabellen können Erkennungsfehler enthalten; Originale bleiben erhalten. Keine automatischen Downloads.","Structured OCR requires a separately verified local model runtime. Text and tables may contain recognition errors; originals are retained. No automatic downloads.")));
    entry(
        &ocr,
        tr("OCR-Sprachen", "OCR languages"),
        "de,en",
        ValueOption::OcrLanguage,
        tr(
            "Sprachkürzel durch Kommas trennen, etwa de,en für Deutsch und Englisch. Leer lassen für die automatische Auswahl.",
            "Separate language codes with commas, such as de,en for German and English. Leave empty for automatic selection.",
        ),
        controls,
    );
    entry(
        &ocr,
        tr("PDF-Seiten", "PDF pages"),
        "1,3-5",
        ValueOption::PdfPages,
        tr(
            "Leer importiert alle Seiten. Mit 1,3-5 werden Seite 1 und die Seiten 3 bis 5 importiert.",
            "Leave empty to import all pages. Enter 1,3-5 to import page 1 and pages 3 through 5.",
        ),
        controls,
    );
    choice(
        &ocr,
        tr("PDF-Layout", "PDF layout"),
        ValueOption::PdfLayout,
        &[
            ("auto", tr("Automatisch", "Automatic")),
            ("legacy", tr("Vorheriges Verfahren", "Legacy extraction")),
        ],
        tr(
            "Automatisch versucht, Spalten und die Lesereihenfolge zu erkennen. Bei ungünstiger Reihenfolge lässt sich das frühere Verfahren ausprobieren.",
            "Automatic tries to identify columns and reading order. Try legacy extraction if the resulting order is hard to read.",
        ),
        controls,
    );
    check(
        &ocr,
        tr(
            "PDF-Kopf-/Fußzeilen entfernen",
            "Remove PDF headers/footers",
        ),
        FlagOption::PdfRemoveHeadersFooters,
        false,
        tr(
            "Entfernt als Kopf- oder Fußzeile erkannte wiederkehrende Zeilen aus der PDF-Ausgabe.",
            "Omits repeated lines identified as headers or footers from the PDF output.",
        ),
        controls,
    );
    check(
        &ocr,
        tr(
            "PDF-Silbentrennung aufheben",
            "Join PDF line breaks in words",
        ),
        FlagOption::PdfDehyphenate,
        false,
        tr(
            "Fügt Wörter zusammen, wenn ein Zeilenumbruch im PDF wahrscheinlich eine Silbentrennung ist.",
            "Joins words when a PDF line break is likely to be a hyphenation break.",
        ),
        controls,
    );
}

fn selection_page(
    notebook: &gtk::Notebook,
    controls: &mut Controls,
) -> (gtk::Button, gtk::DropDown) {
    let selection = page(notebook, tr("Inhaltsauswahl", "Content selection"));
    entry(
        &selection,
        tr("EPUB-Kapitel", "EPUB chapters"),
        "1,3-5",
        ValueOption::EpubChapters,
        tr(
            "Leer importiert alle Kapitel. 1,3-5 wählt Kapitel 1 sowie 3 bis 5. Die Kapitelnummern zeigt die Untersuchung der Quelle.",
            "Leave empty to import all chapters. Enter 1,3-5 for chapters 1 and 3 through 5. Inspect the source to see chapter numbers.",
        ),
        controls,
    );
    entry(
        &selection,
        tr("Tabellenblätter", "Sheets"),
        "all / visible / 1,3-5",
        ValueOption::Sheets,
        tr(
            "Blattnummern angeben, etwa 1,3-5. visible wählt sichtbare Blätter, all alle Blätter. Leer verwendet die Standardeinstellung.",
            "Enter sheet numbers such as 1,3-5. Use visible for visible sheets or all for every sheet. Leave empty for the default.",
        ),
        controls,
    );
    entry(
        &selection,
        tr("Zellbereich", "Cell range"),
        "A1:D20",
        ValueOption::CellRange,
        tr(
            "Beschränkt den Import jedes gewählten Tabellenblatts auf diesen Zellbereich. A1:D20 umfasst Spalten A bis D und Zeilen 1 bis 20.",
            "Limits each selected sheet to the specified cells. A1:D20 covers columns A through D and rows 1 through 20.",
        ),
        controls,
    );
    entry(
        &selection,
        tr("Folien", "Slides"),
        "1,3-5",
        ValueOption::Slides,
        tr(
            "Leer importiert alle Folien. 1,3-5 wählt Folie 1 sowie 3 bis 5.",
            "Leave empty to import all slides. Enter 1,3-5 for slide 1 and slides 3 through 5.",
        ),
        controls,
    );
    choice(
        &selection,
        tr("DOCX-Änderungen", "DOCX changes"),
        ValueOption::DocxChanges,
        &[
            ("accept", tr("Annehmen", "Accept")),
            ("reject", tr("Ablehnen", "Reject")),
            ("mark", tr("Markieren", "Mark")),
        ],
        tr(
            "Bestimmt, wie nachverfolgte Textänderungen in DOCX im Markdown erscheinen. Kommentare behalten Autor, Datum und Fundstelle.",
            "Controls how tracked DOCX edits appear in Markdown. Comments retain author, date and source location.",
        ),
        controls,
    );
    choice(
        &selection,
        tr("Sprechernotizen", "Speaker notes"),
        ValueOption::Notes,
        &[("on", tr("Ein", "On")), ("off", tr("Aus", "Off"))],
        tr(
            "Übernimmt bei Präsentationen auch die Notizen für Vortragende.",
            "Includes presenter notes when converting presentations.",
        ),
        controls,
    );
    let inspect_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let inspect_kind = gtk::DropDown::from_strings(&[
        tr("Blätter", "Sheets"),
        tr("Folien", "Slides"),
        tr("Kapitel", "Chapters"),
    ]);
    inspect_kind.set_tooltip_text(Some(tr(
        "Wählt die Art der Einträge, deren Namen und Nummern angezeigt werden sollen.",
        "Chooses the type of items whose names and numbers will be listed.",
    )));
    let inspect = gtk::Button::with_label(tr("Erste Quelle untersuchen", "Inspect first source"));
    inspect.set_tooltip_text(Some(tr(
        "Zeigt Namen und Nummern für Tabellenblätter, Folien oder Kapitel der ersten Quelle an.",
        "Lists sheet, slide or chapter names and numbers in the first source.",
    )));
    inspect_row.append(&inspect_kind);
    inspect_row.append(&inspect);
    selection.append(&inspect_row);
    (inspect, inspect_kind)
}

fn execution_page(notebook: &gtk::Notebook, controls: &mut Controls) -> gtk::Entry {
    let advanced = page(notebook, tr("Ausführung", "Execution"));
    entry(
        &advanced,
        tr("Parallele Dokumente", "Parallel documents"),
        "1…4 (default 1)",
        ValueOption::Jobs,
        tr(
            "Anzahl der gleichzeitig verarbeiteten Dokumente, von 1 bis 4. Ein höherer Wert kann mehr Arbeitsspeicher beanspruchen.",
            "Number of documents processed at once, from 1 to 4. A higher value may use more memory.",
        ),
        controls,
    );
    entry(
        &advanced,
        tr("Werkzeugzeitlimit (s)", "Tool timeout (s)"),
        "120",
        ValueOption::Timeout,
        tr(
            "Maximale Laufzeit in Sekunden für einen Aufruf eines externen Werkzeugs, etwa Pandoc.",
            "Maximum time in seconds for one call to an external converter such as Pandoc.",
        ),
        controls,
    );
    let pandoc_entry = entry(
        &advanced,
        tr("Pandoc-Pfad", "Pandoc path"),
        "/usr/bin/pandoc",
        ValueOption::Pandoc,
        tr(
            "Optionaler Pfad zur ausführbaren Pandoc-Datei. Leer verwendet die automatische Suche.",
            "Optional path to the Pandoc executable. Leave empty to find it automatically.",
        ),
        controls,
    );
    advanced.append(&label(tr("Profile werden über die CLI im Profilmenü verwaltet. Allgemeine Optionen und Fensterzustand werden gespeichert; Quellauswahl, Pfade und Profilfreigaben bleiben sitzungsgebunden.","Profiles are managed through the CLI in the Profiles menu. General options and window state are saved; source selections, paths and profile permissions remain session-only.")));
    pandoc_entry
}

impl OptionsSection {
    pub(super) fn connect(&self, state: &Shared, view: &View) {
        let state = state.clone();
        let view = view.clone();
        self.choose_destination
            .connect_clicked(move |_| choose_destination(&state, &view));
    }
}

fn choose_destination(state: &Shared, view: &View) {
    let generation = state.borrow().generation;
    let dialog = gtk::FileDialog::builder()
        .title(tr(
            "Neuen Ausgabeordner benennen",
            "Name a new output folder",
        ))
        .initial_name("Markdown-output")
        .build();
    let state = state.clone();
    let view = view.clone();
    dialog.save(
        Some(&view.window.clone()),
        None::<&gio::Cancellable>,
        move |result| {
            let file = match result {
                Ok(file) => file,
                Err(error) => {
                    dialog_error(&view, &error);
                    return;
                }
            };
            if !ticket_current(&state, &view, generation) {
                return;
            }
            let Some(path) = file.path() else {
                reject_remote(&view);
                return;
            };
            if let Some(text) = path.to_str() {
                view.destination.set_text(text);
            } else {
                view.rejection.set_text(tr(
                    "Der Zielname ist kein gültiges UTF-8. Bitte einen anderen Namen wählen.",
                    "The target name is not valid UTF-8. Choose another name.",
                ));
            }
        },
    );
}

fn page(notebook: &gtk::Notebook, title: &str) -> gtk::Box {
    let content = gtk::Box::new(gtk::Orientation::Vertical, 10);
    content.set_margin_top(14);
    content.set_margin_bottom(14);
    content.set_margin_start(14);
    content.set_margin_end(14);
    let scrolled = gtk::ScrolledWindow::builder()
        .child(&content)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vscrollbar_policy(gtk::PolicyType::Always)
        .overlay_scrolling(false)
        .min_content_height(210)
        .build();
    notebook.append_page(&scrolled, Some(&gtk::Label::new(Some(title))));
    content
}
fn entry(
    parent: &gtk::Box,
    title: &str,
    placeholder: &str,
    key: ValueOption,
    help: &str,
    controls: &mut Controls,
) -> gtk::Entry {
    let w = gtk::Entry::builder().placeholder_text(placeholder).build();
    row(parent, title, help, &w);
    controls.check_value_registration(key);
    controls.values.push((key, w.clone()));
    w
}
fn choice(
    parent: &gtk::Box,
    title: &str,
    key: ValueOption,
    items: &[(&'static str, &str)],
    help: &str,
    controls: &mut Controls,
) {
    let labels = items.iter().map(|(_, text)| *text).collect::<Vec<_>>();
    let w = gtk::DropDown::from_strings(&labels);
    row(parent, title, help, &w);
    controls.check_value_registration(key);
    controls.choices.push((
        key,
        Choice {
            widget: w,
            ids: items.iter().map(|(id, _)| *id).collect(),
        },
    ));
}
fn check(
    parent: &gtk::Box,
    title: &str,
    key: FlagOption,
    default: bool,
    help: &str,
    controls: &mut Controls,
) {
    let w = gtk::CheckButton::with_label(title);
    w.set_active(default);
    w.set_tooltip_text(Some(help));
    parent.append(&w);
    controls.register_flag(key, w);
}
