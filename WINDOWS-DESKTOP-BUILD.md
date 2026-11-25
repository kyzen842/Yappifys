# Yappify Windows Desktop

This is a Tauri 2 Windows desktop shell for the hosted Yappify app.

- Launch URL: `https://yappify.lovable.app/auth` (skips the website landing page)
- Product name: Yappify
- Windows icon: copied from the project's `public/favicon.ico`
- Installer: NSIS `.exe`

## Build on GitHub Actions

1. Push this project to a GitHub repository.
2. Open **Actions**.
3. Select **Build Yappify Windows Installer**.
4. Click **Run workflow**.
5. When it completes, open the run and download the `Yappify-Windows-Installer` artifact.
6. The artifact contains `Yappify_1.0.0_x64-setup.exe` (exact name may vary by Tauri version).

## Important

This desktop shell loads the hosted website in a native Windows WebView. The existing website backend, Supabase authentication, and app features remain hosted at Lovable; they are not bundled offline. Users need an internet connection. The app opens at `/auth`, while the website's browser landing page remains unchanged.

The build workflow has been prepared but not executed here. A successful Windows Actions run is required before calling the installer tested.
