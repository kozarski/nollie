# Core models, second pass

What changed, in plain words. Behaviour is the same everywhere; only structure and spelling moved.

- Kanban models: optional fields carry no explicit nil default (a missing key still reads as nil).
  Board, board meta and task initialisers keep their labels and defaults. A task event's timeline
  line comes from an ordered wording list, with the status and blocked kinds handled after it.
- Kanban plugin client: `log` and `comment` each have a short form and a form that names the extra
  argument; the short forms use the old defaults (20,000 bytes, author "nollie"). Reassign builds
  its body from the shared reason fields.
- JSON value: cases listed in another order, decoding tries a list of readers in turn (nil, bool,
  number, string, array, object), each literal conformance is its own extension. Number to bool
  and int reading unchanged.
- Wire request, account, settings and project types: fields listed in another order and
  conformances in another order. Types built by hand (approval request, bot profile, model
  options, project, toolset, scheduled job) have explicit initialisers with the same labels.
  The "Always" scope text for an approval is a switch over the pattern key.
- Generated wire types: the generator lists conformances as Sendable, Hashable, Codable and spells
  optional initialiser arguments as Optional<T> = nil; the generated files were regenerated and the
  generator tests follow.
