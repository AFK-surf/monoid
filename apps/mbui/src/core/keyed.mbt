// A keyed list of a subscription's value as the core changes it (client/core-ts collections.ts: the lists its SPECS
// key, a chat's `messages` by `seq` and `outgoing`): the core sends what changed of such a list item by item (keyed
// `put`, `patch`, `drop`, `move` at its path), and the list here takes each the same way, by key, into an mbui
// KeyedList (@signals.KeyedList): so what reads one item is told only as that item changes, what reads the order only
// as an item comes, goes or moves, and nothing walks the list for a change of one item. The subscription's whole
// value is still kept as before (Sub.value) for what reads it whole; a value that comes whole (its first, one asked
// again, an op that sets the list or what holds it) is taken whole here too, each item compared by identity once.

///|
/// A keyed list of a subscription's value at the top-level field `field`, its items by the core's key of them (the
/// key's JSON text, as the core says it in an op: `key_of`'s), mirrored as the subscription takes each message.
pub struct KeyedField {
  field : String
  /// the item's fields its key is made of, as the core's spec says them (["seq", "outgoing"])
  key_fields : Array[Json]
  list : @signals.KeyedList[String, Json]
}

///|
/// The canonical wire-key text of `item` by `fields` (matching `delta.mbt`'s `key_text` / `json_key_text`).
fn KeyedField::item_key(self : KeyedField, item : Json) -> String {
  key_text(item, self.key_fields)
}

///|
/// The list taken whole from `value` (its field's array; none there, empty).
fn KeyedField::take_whole(self : KeyedField, value : Json?) -> Unit {
  let items = match value {
    Some(Object(m)) =>
      match m.get(self.field) {
        Some(Array(a)) => a
        _ => []
      }
    _ => []
  }
  let keys : Array[String] = []
  let vals : Map[String, Json] = Map([])
  for item in items {
    let k = self.item_key(item)
    if !vals.contains(k) {
      keys.push(k)
      vals[k] = item
    }
  }
  self.list.reset(keys, vals)
}

///|
/// What message ops `ops` (a `delta`'s, applied to the value as they come) did to the list: each keyed op at its
/// path by key, nothing else read; where one sets or removes the list or what holds it, or reaches into it by index,
/// the list taken whole from `value` (the value with them applied) instead.
fn KeyedField::take_ops(self : KeyedField, ops : Array[Json], value : Json?) -> Unit {
  @signals.start_batch()
  for op in ops {
    guard op is Object(o) else { continue }
    match o.get("path") {
      Some(Array(p)) =>
        if p.length() == 0 || !(p[0] is String(f) && f == self.field) {
          // (another field, or the whole value)
          if p.length() == 0 {
            self.take_whole(value)
            break
          }
        } else if p.length() != 1 {
          // (into an item by its index: not said by key)
          self.take_whole(value)
          break
        } else if o.get("key") is Some(_) {
          self.take_keyed(o)
        } else {
          // (the list set, appended to or removed whole)
          self.take_whole(value)
          break
        }
      _ => ()
    }
  }
  @signals.end_batch()
}

///|
/// One keyed op `o` of the list, by key.
fn KeyedField::take_keyed(self : KeyedField, o : Map[String, Json]) -> Unit {
  let before = match o.get("before") {
    None | Some(Null) => None
    Some(b) => Some(json_key_text(b))
  }
  match (o.get("drop"), o.get("patch"), o.get("move"), o.get("put")) {
    (Some(k), _, _, _) => self.list.drop(json_key_text(k))
    (None, Some(k), _, _) => {
      let key = json_key_text(k)
      match (self.list.peek(key), o.get("ops")) {
        (Some(was), Some(Array(inner))) => {
          let now = apply_delta(was, inner)
          let key_now = self.item_key(now)
          if key_now == key {
            self.list.put(key, now)
          } else {
            // (its key changed by the patch: the item under its new key, where it was)
            let order = self.list.peek_keys()
            let mut next : String? = None
            for i, x in order {
              if x == key && i + 1 < order.length() {
                next = Some(order[i + 1])
              }
            }
            self.list.drop(key)
            self.list.put(key_now, now, before=next)
          }
        }
        _ => ()
      }
    }
    (None, None, Some(k), _) => self.list.move_before(json_key_text(k), before~)
    (None, None, None, Some(item)) => {
      let key = self.item_key(item)
      match self.list.peek(key) {
        // (put again: its value, where it is, or where `before` says where the op says one)
        Some(_) => {
          self.list.put(key, item)
          if o.contains("before") {
            self.list.move_before(key, before~)
          }
        }
        None => self.list.put(key, item, before~)
      }
    }
    _ => ()
  }
}
