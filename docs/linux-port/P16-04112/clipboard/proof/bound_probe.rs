use pmt_bridge::{BoundInput, Bridge, Event, InputName};
use std::{ffi::OsString, path::PathBuf};
fn main() {
    let mut args = std::env::args_os().skip(1);
    let cli = PathBuf::from(args.next().unwrap());
    let guard = PathBuf::from(args.next().unwrap());
    let source = PathBuf::from(args.next().unwrap());
    let bytes = std::fs::read(&source).unwrap();
    let ext = source.extension().unwrap().to_str().unwrap();
    let input =
        BoundInput::new(&bytes, InputName::new(&format!("clipboard.{ext}")).unwrap()).unwrap();
    let preview = std::env::var_os("PMT_BOUND_PREVIEW").is_some();
    let no_input = std::env::var_os("PMT_BOUND_NO_INPUT").is_some();
    let operation = std::env::var_os("PMT_BOUND_OPERATION").is_some();
    let mut arguments: Vec<OsString> = args.collect();
    if operation {
        arguments.extend([
            "--profile-source".into(),
            if no_input {
                source.clone().into_os_string()
            } else {
                input.path().into_os_string()
            },
        ]);
    } else {
        arguments.extend([
            "--".into(),
            if no_input {
                source.clone().into_os_string()
            } else {
                input.path().into_os_string()
            },
        ]);
    }
    let bridge = Bridge::new(cli).with_guard(guard);
    let bridge = if no_input {
        bridge
    } else {
        bridge.with_input(input)
    };
    let job = if operation || preview {
        bridge.start_operation(arguments)
    } else {
        bridge.start_conversion(arguments)
    };
    loop {
        match job.events.recv().unwrap() {
            Event::ProgressText(_) => (),
            Event::Finished(result) => {
                match result {
                    Ok(v) => println!("{}", v),
                    Err(e) => {
                        eprintln!("{e} CORE_EXIT={:?}", e.exit_code);
                        std::process::exit(1);
                    }
                };
                break;
            }
        }
    }
}
