use tauri::{webview::WebviewWindowBuilder, WebviewUrl};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            let url = "https://yappify.lovable.app/auth".parse()
                .expect("valid Yappify URL");
            WebviewWindowBuilder::new(app, "main", WebviewUrl::External(url))
                .title("Yappify")
                .inner_size(1200.0, 800.0)
                .min_inner_size(800.0, 600.0)
                .resizable(true)
                .center()
                .build()?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Yappify Desktop");
}
