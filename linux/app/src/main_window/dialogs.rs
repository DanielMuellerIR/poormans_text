use crate::{Shared, View, model::tr};
use gtk::{gio, glib};

pub(crate) fn reject_remote(view: &View) {
    view.rejection.set_text(tr(
        "Nur lokale Dateien und Ordner werden angenommen.",
        "Only local files and folders are accepted.",
    ));
}
pub(crate) fn ticket_current(state: &Shared, view: &View, generation: u64) -> bool {
    if state.borrow().generation != generation || state.borrow().is_busy() {
        view.rejection.set_text(tr(
            "Die Auswahl wurde durch neue Quellen oder einen Lauf überholt. Bitte erneut wählen.",
            "New sources or a job superseded this selection. Choose again.",
        ));
        false
    } else {
        true
    }
}

pub(crate) fn dialog_error(view: &View, error: &glib::Error) {
    if error.matches(gtk::DialogError::Cancelled)
        || error.matches(gtk::DialogError::Dismissed)
        || error.matches(gio::IOErrorEnum::Cancelled)
    {
        return;
    }
    view.rejection.set_text(&format!(
        "{}: {}",
        tr("Dateiauswahl fehlgeschlagen", "File selection failed"),
        error
    ));
    #[cfg(feature = "ui-self-test")]
    crate::self_test::dialog_failed(error);
}
