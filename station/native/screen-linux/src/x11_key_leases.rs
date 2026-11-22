// X11 keymaps outlive the client that changed them. Mark each temporary mapping with an X11
// selection so the next view can recover it if the view that made it exits unexpectedly.

use x11rb::connection::Connection;
use x11rb::protocol::xproto::{
    Atom, AtomEnum, ConnectionExt as XprotoExt, CreateWindowAux, PropMode, Window, WindowClass,
};
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as WrapperExt;
use x11rb::{COPY_DEPTH_FROM_PARENT, CURRENT_TIME};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Lease {
    keycode: u8,
    owner: Window,
    previous: u32,
    next: u32,
}

fn matches_mapping(mapping: &[u32], keysym: u32) -> bool {
    keysym != 0
        && mapping.iter().any(|&s| s == keysym)
        && mapping.iter().all(|&s| s == 0 || s == keysym)
}

fn was_ours(mapping: &[u32], lease: Lease) -> bool {
    matches_mapping(mapping, lease.previous) || matches_mapping(mapping, lease.next)
}

pub struct KeyLeases {
    root: Window,
    owner: Window,
    property: Atom,
}

impl KeyLeases {
    pub fn open(conn: &RustConnection, root: Window) -> Result<Self, String> {
        let owner = conn.generate_id().map_err(|e| e.to_string())?;
        conn.create_window(
            COPY_DEPTH_FROM_PARENT,
            owner,
            root,
            0,
            0,
            1,
            1,
            0,
            WindowClass::INPUT_ONLY,
            0,
            &CreateWindowAux::new(),
        )
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
        let property = conn
            .intern_atom(false, b"_STILLFAIL_SCREEN_X11_KEYS_V1")
            .map_err(|e| e.to_string())?
            .reply()
            .map_err(|e| e.to_string())?
            .atom;
        let this = Self {
            root,
            owner,
            property,
        };
        this.locked(conn, || this.recover(conn))?;
        Ok(this)
    }

    fn locked<T>(
        &self,
        conn: &RustConnection,
        action: impl FnOnce() -> Result<T, String>,
    ) -> Result<T, String> {
        conn.grab_server()
            .map_err(|e| e.to_string())?
            .check()
            .map_err(|e| e.to_string())?;
        let result = action();
        let unlocked = conn
            .ungrab_server()
            .map_err(|e| e.to_string())
            .and_then(|c| c.check().map_err(|e| e.to_string()));
        result.and_then(|value| unlocked.map(|()| value))
    }

    fn selection(conn: &RustConnection, keycode: u8) -> Result<Atom, String> {
        let name = format!("_STILLFAIL_SCREEN_X11_KEY_{keycode}");
        Ok(conn
            .intern_atom(false, name.as_bytes())
            .map_err(|e| e.to_string())?
            .reply()
            .map_err(|e| e.to_string())?
            .atom)
    }

    fn read(&self, conn: &RustConnection) -> Result<Vec<Lease>, String> {
        let p = conn
            .get_property(false, self.root, self.property, AtomEnum::CARDINAL, 0, 1024)
            .map_err(|e| e.to_string())?
            .reply()
            .map_err(|e| e.to_string())?;
        if p.type_ == u32::from(AtomEnum::NONE) {
            return Ok(Vec::new());
        }
        if p.type_ != u32::from(AtomEnum::CARDINAL) || p.format != 32 || p.bytes_after != 0 {
            return Err("invalid X11 key lease property".to_string());
        }
        let values: Vec<u32> = p.value32().ok_or("invalid X11 key lease data")?.collect();
        if values.len() % 4 != 0 {
            return Err("incomplete X11 key lease data".to_string());
        }
        values
            .chunks_exact(4)
            .map(|v| {
                Ok(Lease {
                    keycode: u8::try_from(v[0]).map_err(|_| "invalid keycode")?,
                    owner: v[1],
                    previous: v[2],
                    next: v[3],
                })
            })
            .collect()
    }

    fn write(&self, conn: &RustConnection, leases: &[Lease]) -> Result<(), String> {
        if leases.is_empty() {
            conn.delete_property(self.root, self.property)
                .map_err(|e| e.to_string())?
                .check()
                .map_err(|e| e.to_string())?;
        } else {
            let values: Vec<u32> = leases
                .iter()
                .flat_map(|l| [u32::from(l.keycode), l.owner, l.previous, l.next])
                .collect();
            conn.change_property32(
                PropMode::REPLACE,
                self.root,
                self.property,
                AtomEnum::CARDINAL,
                &values,
            )
            .map_err(|e| e.to_string())?
            .check()
            .map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    fn mapping(conn: &RustConnection, keycode: u8) -> Result<Vec<u32>, String> {
        Ok(conn
            .get_keyboard_mapping(keycode, 1)
            .map_err(|e| e.to_string())?
            .reply()
            .map_err(|e| e.to_string())?
            .keysyms)
    }

    fn set_mapping(conn: &RustConnection, keycode: u8, mapping: &[u32]) -> Result<(), String> {
        let width =
            u8::try_from(mapping.len()).map_err(|_| "invalid X11 keyboard mapping width")?;
        conn.change_keyboard_mapping(1, keycode, width, mapping)
            .map_err(|e| e.to_string())?
            .check()
            .map_err(|e| e.to_string())
    }

    fn selection_owner(conn: &RustConnection, selection: Atom) -> Result<Window, String> {
        Ok(conn
            .get_selection_owner(selection)
            .map_err(|e| e.to_string())?
            .reply()
            .map_err(|e| e.to_string())?
            .owner)
    }

    // Called with the server grabbed. Never overwrite a keymap changed by another client.
    fn recover(&self, conn: &RustConnection) -> Result<(), String> {
        let leases = self.read(conn)?;
        let mut kept = Vec::new();
        for lease in leases.iter().copied() {
            let selection = Self::selection(conn, lease.keycode)?;
            if Self::selection_owner(conn, selection)? != 0 {
                kept.push(lease);
                continue;
            }
            let mapping = Self::mapping(conn, lease.keycode)?;
            if was_ours(&mapping, lease) {
                Self::set_mapping(conn, lease.keycode, &vec![0; mapping.len()])?;
            }
        }
        if kept.len() != leases.len() {
            self.write(conn, &kept)?;
        }
        Ok(())
    }

    /// Reserve a still-empty keycode, or update one already reserved by this view.
    pub fn map(&self, conn: &RustConnection, keycode: u8, keysym: u32) -> Result<bool, String> {
        self.locked(conn, || {
            let mut leases = self.read(conn)?;
            let selection = Self::selection(conn, keycode)?;
            let owner = Self::selection_owner(conn, selection)?;
            let mapping = Self::mapping(conn, keycode)?;
            let position = leases.iter().position(|l| l.keycode == keycode);
            let previous = if let Some(i) = position {
                if owner != self.owner
                    || leases[i].owner != self.owner
                    || !was_ours(&mapping, leases[i])
                {
                    return Ok(false);
                }
                leases[i].next
            } else {
                if owner != 0 || mapping.iter().any(|&s| s != 0) {
                    return Ok(false);
                }
                conn.set_selection_owner(self.owner, selection, CURRENT_TIME)
                    .map_err(|e| e.to_string())?
                    .check()
                    .map_err(|e| e.to_string())?;
                0
            };
            let lease = Lease {
                keycode,
                owner: self.owner,
                previous,
                next: keysym,
            };
            if let Some(i) = position {
                leases[i] = lease;
            } else {
                leases.push(lease);
            }
            // Record both mappings before changing the server, so either can be recovered on exit.
            self.write(conn, &leases)?;
            Self::set_mapping(conn, keycode, &vec![keysym; mapping.len()])?;
            // Once the server confirms the change, the previous symbol is no longer needed.
            if let Some(lease) = leases.iter_mut().find(|l| l.keycode == keycode) {
                lease.previous = 0;
            }
            self.write(conn, &leases)?;
            Ok(true)
        })
    }

    pub fn release(&self, conn: &RustConnection) -> Result<(), String> {
        self.locked(conn, || {
            let leases = self.read(conn)?;
            let mut kept = Vec::new();
            for lease in leases {
                if lease.owner != self.owner {
                    kept.push(lease);
                    continue;
                }
                let selection = Self::selection(conn, lease.keycode)?;
                if Self::selection_owner(conn, selection)? != self.owner {
                    kept.push(lease);
                    continue;
                }
                let mapping = Self::mapping(conn, lease.keycode)?;
                if was_ours(&mapping, lease) {
                    Self::set_mapping(conn, lease.keycode, &vec![0; mapping.len()])?;
                }
                conn.set_selection_owner(0u32, selection, CURRENT_TIME)
                    .map_err(|e| e.to_string())?
                    .check()
                    .map_err(|e| e.to_string())?;
            }
            self.write(conn, &kept)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_both_sides_of_an_interrupted_remap_without_touching_other_keys() {
        let lease = Lease {
            keycode: 248,
            owner: 123,
            previous: 0x61,
            next: 0x62,
        };
        assert!(was_ours(&[0x61, 0x61, 0], lease));
        assert!(was_ours(&[0x62, 0x62, 0], lease));
        assert!(!was_ours(&[0x63, 0x63, 0], lease));
        assert!(!was_ours(&[0x61, 0x63, 0], lease));
        assert!(!was_ours(&[0, 0, 0], lease));
    }
}
