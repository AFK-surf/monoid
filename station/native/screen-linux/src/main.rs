// stillfail-screen-linux: native Linux desktop capture, OpenH264/JPEG encoding, and input helper.
// Speaks the same 5-byte big-endian binary pipe protocol as Windows `stillfail-screen` and macOS `still.fail Helper`
// (`station/src/screens/desktop.ts` `HelperView`).

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod avc;
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod cursor_image;
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod diff;
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod encode;
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod input_queue;
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod pace;
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod protocol;
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod region;
#[cfg(target_os = "linux")]
mod view;
#[cfg(target_os = "linux")]
mod wayland;
#[cfg(target_os = "linux")]
mod x11;
#[cfg(target_os = "linux")]
mod x11_key_leases;

#[cfg(target_os = "linux")]
fn main() {
    match std::env::args().nth(1).as_deref() {
        Some("status") => println!("{}", view::status()),
        Some("view") => {
            let Some(request) = ({
                let mut input = std::io::stdin().lock();
                protocol::request_line(&mut input)
            }) else {
                std::process::exit(2);
            };
            view::run(&request, protocol::Out::new());
        }
        _ => {
            eprintln!("usage: stillfail-screen-linux status | view");
            std::process::exit(2);
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("stillfail-screen-linux is for Linux");
    std::process::exit(2);
}
