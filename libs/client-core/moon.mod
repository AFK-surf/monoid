name = "client_core"

version = "0.1.0"

source = "src"

preferred_target = "native"

// As the base's and mbui's own line: a warning is an error or off, never left a warning.
warnings = "@a-33-79-29"

import {
  "base@0.1.0",
  "ui@0.1.0",
}
