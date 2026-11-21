use super::*;
use crate::bounded_dropdown;

pub(super) struct View {
    pub(super) source: SourceView,
    pub(super) mask: MaskView,
    pub(super) footer: FooterView,
}

impl View {
    pub(super) fn new(window: &gtk::Window) -> Self {
        let outer = padded(12, 18);
        let split = gtk::Paned::new(gtk::Orientation::Horizontal);
        split.set_vexpand(true);
        split.set_wide_handle(true);
        split.set_position(560);
        split.set_shrink_start_child(false);
        split.set_shrink_end_child(false);
        split.set_resize_start_child(true);
        outer.append(&split);

        let source = SourceView::new();
        split.set_start_child(Some(&source.container));
        let mask = MaskView::new();
        split.set_end_child(Some(&mask.scrolled));
        let footer = FooterView::new(&outer);
        window.set_child(Some(&outer));
        Self {
            source,
            mask,
            footer,
        }
    }
}

pub(super) struct SourceView {
    pub(super) container: gtk::Box,
    pub(super) picture: SourceCanvas,
    pub(super) viewport: gtk::ScrolledWindow,
    pub(super) filename: gtk::Label,
    pub(super) doc_count: gtk::Label,
    pub(super) page_count: gtk::Label,
    pub(super) source_status: gtk::Label,
    pub(super) reload_source: gtk::Button,
    pub(super) retry: gtk::Button,
    pub(super) add: gtk::Button,
    pub(super) previous_pdf: gtk::Button,
    pub(super) next_pdf: gtk::Button,
    pub(super) previous_page: gtk::Button,
    pub(super) next_page: gtk::Button,
    pub(super) zoom_out: gtk::Button,
    pub(super) fit: gtk::Button,
    pub(super) zoom_in: gtk::Button,
}

impl SourceView {
    fn new() -> Self {
        let container = padded(8, 0);
        container.set_size_request(320, -1);
        let add = gtk::Button::with_label(tr("PDFs hinzufügen…", "Add PDFs…"));
        add.set_tooltip_text(Some(tr(
            "Fügt weitere Belege desselben Geschäftspartners hinzu, um dieselben Regeln zu testen.",
            "Adds more receipts from the same business partner to test the same rules.",
        )));
        let previous_pdf = icon("go-previous-symbolic", tr("Vorheriges PDF", "Previous PDF"));
        previous_pdf.set_tooltip_text(Some(tr(
            "Prüft dieselbe Maske am vorherigen PDF in der Liste.",
            "Tests the same mask against the previous PDF in the list.",
        )));
        let next_pdf = icon("go-next-symbolic", tr("Nächstes PDF", "Next PDF"));
        next_pdf.set_tooltip_text(Some(tr(
            "Prüft dieselbe Maske am nächsten PDF in der Liste.",
            "Tests the same mask against the next PDF in the list.",
        )));
        let doc_count = gtk::Label::new(None);
        let docs = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        docs.append(&add);
        let doc_nav = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        doc_nav.set_hexpand(true);
        doc_nav.set_halign(gtk::Align::End);
        doc_nav.append(&previous_pdf);
        doc_nav.append(&doc_count);
        doc_nav.append(&next_pdf);
        docs.append(&doc_nav);
        container.append(&docs);
        let filename = single_line("");
        filename.add_css_class("heading");
        container.append(&filename);

        let previous_page = icon(
            "go-previous-symbolic",
            tr("Vorherige Seite", "Previous page"),
        );
        previous_page.set_tooltip_text(Some(tr(
            "Zeigt die vorherige Seite im aktuellen PDF.",
            "Shows the previous page of the current PDF.",
        )));
        let next_page = icon("go-next-symbolic", tr("Nächste Seite", "Next page"));
        next_page.set_tooltip_text(Some(tr(
            "Zeigt die nächste Seite im aktuellen PDF.",
            "Shows the next page of the current PDF.",
        )));
        let page_count = gtk::Label::new(None);
        let zoom_out = icon("zoom-out-symbolic", tr("Verkleinern", "Zoom out"));
        let fit = gtk::Button::with_label(tr("Einpassen", "Fit"));
        fit.set_tooltip_text(Some(tr(
            "Passt die PDF-Seite in die Vorschau ein.",
            "Fits the PDF page in the preview.",
        )));
        let zoom_in = icon("zoom-in-symbolic", tr("Vergrößern", "Zoom in"));
        let page_nav = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        page_nav.append(&previous_page);
        page_nav.append(&page_count);
        page_nav.append(&next_page);
        let zoom = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        zoom.set_hexpand(true);
        zoom.set_halign(gtk::Align::End);
        zoom.append(&zoom_out);
        zoom.append(&fit);
        zoom.append(&zoom_in);
        page_nav.append(&zoom);
        container.append(&page_nav);
        let picture = SourceCanvas::new();
        picture.set_tooltip_text(Some(tr(
        "Auf ein Wort klicken oder einen Rahmen ziehen, um einen Textbereich für eine Regel zu wählen.",
        "Click a word or drag a rectangle to select a text region for a rule.",
    )));
        picture.update_property(&[gtk::accessible::Property::Label(tr(
            "PDF-Quelle",
            "Source PDF",
        ))]);
        let viewport = gtk::ScrolledWindow::builder()
            .child(&picture)
            .has_frame(true)
            .hexpand(true)
            .vexpand(true)
            .min_content_height(270)
            .build();
        container.append(&viewport);
        let source_status = label("");
        source_status.add_css_class("dim-label");
        source_status.set_selectable(true);
        container.append(&source_status);
        let retry = gtk::Button::with_label(tr("Erneut versuchen", "Retry"));
        retry.set_halign(gtk::Align::Start);
        let reload_source = gtk::Button::with_label(tr("PDF neu laden", "Reload PDF"));
        reload_source.set_tooltip_text(Some(tr(
        "Liest die aktuelle PDF-Datei neu ein und verwirft die Korrekturen dieses Belegs. Der Maskenentwurf bleibt erhalten.",
        "Reads the current PDF again and discards corrections for this receipt. Keeps the mask draft.",
    )));
        let recovery = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        recovery.append(&retry);
        recovery.append(&reload_source);
        container.append(&recovery);
        Self {
            container,
            picture,
            viewport,
            filename,
            doc_count,
            page_count,
            source_status,
            reload_source,
            retry,
            add,
            previous_pdf,
            next_pdf,
            previous_page,
            next_page,
            zoom_out,
            fit,
            zoom_in,
        }
    }
}

pub(super) struct MaskView {
    pub(super) scrolled: gtk::ScrolledWindow,
    pub(super) clear_region: gtk::Button,
    pub(super) partner: gtk::Entry,
    pub(super) document_type: gtk::Entry,
    pub(super) mask_file: gtk::Label,
    pub(super) selected: gtk::Box,
    pub(super) selected_region: gtk::Label,
    pub(super) replace: gtk::DropDown,
    pub(super) suggestions: gtk::Box,
    pub(super) fields: gtk::Box,
    pub(super) load: gtk::Button,
    pub(super) reload: gtk::Button,
    pub(super) save: gtk::Button,
    pub(super) add_region: gtk::Button,
    pub(super) replace_region: gtk::Button,
}

impl MaskView {
    fn new() -> Self {
        let right = padded(10, 12);
        section(&right, tr("Extraktionsmaske", "Extraction mask"));
        let partner = gtk::Entry::new();
        partner.set_tooltip_text(Some(tr(
            "Name des Geschäftspartners, für dessen Belege diese Maske gedacht ist.",
            "Name of the business partner whose receipts use this mask.",
        )));
        let document_type = gtk::Entry::new();
        document_type.set_tooltip_text(Some(tr(
            "Kategorie der Belege in dieser Maske, etwa Rechnung oder Lieferschein.",
            "Category of receipts covered by this mask, such as invoice or delivery note.",
        )));
        let metadata = gtk::Grid::builder()
            .row_spacing(8)
            .column_spacing(12)
            .build();
        for (index, (title, entry)) in [
            (tr("Partner", "Partner"), &partner),
            (tr("Dokumenttyp", "Document type"), &document_type),
        ]
        .into_iter()
        .enumerate()
        {
            let name = label(title);
            name.set_mnemonic_widget(Some(entry));
            entry.update_property(&[gtk::accessible::Property::Label(title)]);
            entry.set_hexpand(true);
            entry.set_width_chars(1);
            metadata.attach(&name, 0, index as i32, 1, 1);
            metadata.attach(entry, 1, index as i32, 1, 1);
        }
        right.append(&metadata);
        let load = gtk::Button::with_label(tr("Maske laden…", "Load mask…"));
        load.set_tooltip_text(Some(tr(
            "Öffnet eine gespeicherte JSON-Maske und prüft ihre Regeln am aktuellen PDF.",
            "Opens a saved JSON mask and tests its rules against the current PDF.",
        )));
        let reload = icon(
            "view-refresh-symbolic",
            tr("Maske neu laden", "Reload mask"),
        );
        reload.set_tooltip_text(Some(tr(
            "Liest die Maskendatei erneut ein und verwirft ungespeicherte Änderungen an der Maske.",
            "Reads the mask file again and discards unsaved mask changes.",
        )));
        let save = gtk::Button::with_label(tr("Maske speichern…", "Save mask…"));
        save.set_tooltip_text(Some(tr(
            "Speichert die Regeln als wiederverwendbare JSON-Maske.",
            "Saves the rules as a reusable JSON mask.",
        )));
        buttons(&right, &[&load, &reload, &save]);
        let mask_file = single_line("");
        mask_file.add_css_class("dim-label");
        right.append(&mask_file);

        let selected = padded(8, 0);
        section(&selected, tr("Ausgewählter Bereich", "Selected region"));
        let selected_region = label("");
        selected.append(&selected_region);
        let add_region = gtk::Button::with_label(tr("Neues Bereichsfeld", "New region field"));
        add_region.set_tooltip_text(Some(tr(
            "Legt ein Feld an, das Text auf dieser Seite an derselben Position liest.",
            "Creates a field that reads text at the same position on this page.",
        )));
        let clear_region = gtk::Button::with_label(tr("Aufheben", "Clear selection"));
        clear_region.set_tooltip_text(Some(tr(
            "Hebt die Auswahl im PDF auf.",
            "Clears the selection in the PDF.",
        )));
        buttons(&selected, &[&add_region, &clear_region]);
        let replace_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let replace = gtk::DropDown::from_strings(&[]);
        replace.set_tooltip_text(Some(tr(
            "Wählt das Feld, das künftig den markierten Bereich verwenden soll.",
            "Chooses the field that should use the selected region.",
        )));
        replace.set_hexpand(true);
        replace.update_property(&[gtk::accessible::Property::Label(tr(
            "Feld, dessen Regel ersetzt wird",
            "Field whose rule will be replaced",
        ))]);
        bounded_dropdown(&replace);
        let replace_region = gtk::Button::with_label(tr("Regel ersetzen", "Replace rule"));
        replace_region.set_tooltip_text(Some(tr(
            "Ersetzt die Suchregel des gewählten Felds durch den markierten PDF-Bereich.",
            "Replaces the selected field’s extraction rule with the marked PDF region.",
        )));
        replace_row.append(&replace);
        replace_row.append(&replace_region);
        selected.append(&replace_row);
        right.append(&selected);

        let suggestions = padded(8, 0);
        right.append(&suggestions);
        let fields = padded(10, 0);
        right.append(&fields);
        let scrolled = gtk::ScrolledWindow::builder()
            .child(&right)
            .width_request(380)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .overlay_scrolling(false)
            .has_frame(true)
            .build();
        Self {
            scrolled,
            clear_region,
            partner,
            document_type,
            mask_file,
            selected,
            selected_region,
            replace,
            suggestions,
            fields,
            load,
            reload,
            save,
            add_region,
            replace_region,
        }
    }
}

pub(super) struct FooterView {
    pub(super) status: gtk::Label,
    pub(super) preview_json: gtk::Button,
    pub(super) export: gtk::Button,
    pub(super) cancel: gtk::Button,
    pub(super) batch: gtk::Button,
}

impl FooterView {
    fn new(outer: &gtk::Box) -> Self {
        let status = label("");
        status.set_selectable(true);
        status.set_visible(false);
        status.connect_label_notify(|label| label.set_visible(!label.label().is_empty()));
        outer.append(&status);
        let preview_json = gtk::Button::with_label(tr("JSON-Vorschau", "Preview JSON"));
        preview_json.set_tooltip_text(Some(tr(
        "Zeigt Werte und Prüfstatus des aktuellen Belegs vor dem Speichern. Fehlende oder mehrdeutige Werte erscheinen als null.",
        "Shows values and review statuses for the current receipt before saving. Missing or ambiguous values appear as null.",
    )));
        let export = gtk::Button::with_label(tr("JSON exportieren…", "Export JSON…"));
        export.set_tooltip_text(Some(tr(
        "Speichert die Werte und Prüfstatus des aktuellen Belegs einschließlich seiner Korrekturen als JSON.",
        "Saves current values and review statuses, including corrections for this receipt, as JSON.",
    )));
        export.add_css_class("suggested-action");
        let cancel = gtk::Button::with_label(tr("Abbrechen", "Cancel"));
        let batch = gtk::Button::with_label(tr("Stapelverarbeitung…", "Batch extraction…"));
        batch.set_tooltip_text(Some(tr(
            "Öffnet die Stapelverarbeitung für mehrere PDF-Belege.",
            "Opens batch extraction for multiple PDF receipts.",
        )));
        let footer = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        footer.append(&batch);
        footer.append(&cancel);
        let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        footer.append(&spacer);
        footer.append(&preview_json);
        footer.append(&export);
        outer.append(&footer);
        Self {
            status,
            preview_json,
            export,
            cancel,
            batch,
        }
    }
}
