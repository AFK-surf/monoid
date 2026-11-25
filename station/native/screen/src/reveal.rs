// Which paths a view may show selected in Explorer (view.rs `reveal`). Apart from view.rs so its tests run on every
// platform. The path comes from the other end of the view, and goes on Explorer's command line
// (`/select,"<path>"`): only a plain drive path of an existing file is taken, never a share (`\\host\…`, which makes
// Windows reach the network and hand it this user's credentials), a device path (`\\?\…`, `\\.\…`), a shell location
// (`shell:…`) or a relative path, which Explorer would resolve or open as something else.
pub fn is_safe_reveal_path(path: &str) -> bool {
    let b = path.as_bytes();
    if b.len() < 4 || path.contains('"') || path.chars().any(char::is_control) {
        return false;
    }
    if path.ends_with(['\\', '/']) || path.starts_with("\\\\") || path.starts_with("//") {
        return false;
    }
    b[0].is_ascii_alphabetic() && b[1] == b':' && (b[2] == b'\\' || b[2] == b'/')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn takes_drive_paths_of_files() {
        assert!(is_safe_reveal_path(r"C:\Users\pengx\Downloads\a.png"));
        assert!(is_safe_reveal_path(r"d:\x"));
        assert!(is_safe_reveal_path("C:/Users/pengx/a b, c.txt"));
        assert!(is_safe_reveal_path(r"C:\Users\彭\文件.txt"));
    }

    #[test]
    fn refuses_everything_else() {
        assert!(!is_safe_reveal_path(""));
        assert!(!is_safe_reveal_path(r"C:\"));
        assert!(!is_safe_reveal_path(r"C:\Users\"));
        assert!(!is_safe_reveal_path("C:/Users/"));
        assert!(!is_safe_reveal_path(r#"C:\a" /e,"C:\b"#));
        assert!(!is_safe_reveal_path("C:\\a\nb"));
        assert!(!is_safe_reveal_path("C:\\a\0b"));
        assert!(!is_safe_reveal_path("C:\\a\tb"));
        assert!(!is_safe_reveal_path(r"\\attacker\share\a.txt"));
        assert!(!is_safe_reveal_path("//attacker/share/a.txt"));
        assert!(!is_safe_reveal_path(r"\\?\C:\a.txt"));
        assert!(!is_safe_reveal_path(r"\\.\pipe\x"));
        assert!(!is_safe_reveal_path("shell:startup"));
        assert!(!is_safe_reveal_path("shell:::{20D04FE0-3AEA-1069-A2D8-08002B30309D}"));
        assert!(!is_safe_reveal_path(r"Downloads\a.txt"));
        assert!(!is_safe_reveal_path(r"..\a.txt"));
        assert!(!is_safe_reveal_path(r"\Windows\a.txt"));
        assert!(!is_safe_reveal_path(r"C:a.txt"));
        assert!(!is_safe_reveal_path(r"1:\a.txt"));
        assert!(!is_safe_reveal_path("file:///C:/a.txt"));
    }
}
