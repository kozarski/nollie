#!/usr/bin/env python3
"""Turn Hermes's OpenRPC gateway contract into Swift wire types for NollieCore.

    python3 Tools/codegen/gateway_contract.py [--contract PATH] [--check]

Reads the contract (by default from the Hermes checkout at ~/.hermes/hermes-agent), and writes:

- Packages/NollieCore/Sources/NollieCore/Gateway/Generated/GatewayWire*.swift: one type per schema inside
  the GatewayWire namespace, plus typed descriptors for calls, server questions and events.
- Tests/Unit/Generated/GatewayWireSamples.swift: a full and a minimal sample object for every type, so a
  test can decode and re-encode each one.

--check compares instead of writing and exits 1 when the checked-in files are out of date. The output depends
only on the contract, so running it twice gives identical files. See Docs/specs/gateway-client.md.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONTRACT = Path.home() / ".hermes/hermes-agent/apps/shared/src/gateway-contract.openrpc.json"
SOURCE_DIR = ROOT / "Packages/NollieCore/Sources/NollieCore/Gateway/Generated"
SAMPLES_FILE = ROOT / "Tests/Unit/Generated/GatewayWireSamples.swift"
TYPE_FILES = 6
REF_PREFIX = "#/components/schemas/"

SWIFT_KEYWORDS = {
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
    "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows",
    "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default",
    "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch",
    "where", "while", "as", "false", "is", "nil", "super", "throws", "true", "try", "any", "some",
}
# Names Swift will not take even in backticks, or that would shadow something every type relies on.
AWKWARD_NAMES = {"self", "Self", "Type", "Protocol", "init", "rawValue", "hashValue", "description"}


class ContractError(Exception):
    pass


# Naming

def words(text: str) -> list[str]:
    """Split a wire name into words: snake_case, kebab-case, dotted, camelCase and digits all break."""
    spaced = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", text)
    return [w for w in re.split(r"[^A-Za-z0-9]+", spaced) if w]


def upper_camel(text: str) -> str:
    joined = "".join(w[:1].upper() + w[1:] for w in words(text))
    if not joined:
        joined = "Value"
    if joined[0].isdigit():
        joined = "N" + joined
    if joined in AWKWARD_NAMES or joined in SWIFT_KEYWORDS:
        joined += "Kind"
    return joined


def lower_camel(text: str) -> str:
    parts = words(text)
    if not parts:
        return "value"
    first = parts[0]
    first = first.lower() if first.isupper() and len(first) > 1 else first[:1].lower() + first[1:]
    joined = first + "".join(w[:1].upper() + w[1:] for w in parts[1:])
    if joined[0].isdigit():
        joined = "n" + joined
    return joined


def member_name(text: str, taken: set[str]) -> str:
    """A property or case name that is a valid Swift identifier and unique within its type."""
    name = lower_camel(text)
    if name in AWKWARD_NAMES:
        name += "Value"
    base, n = name, 2
    while name in taken:
        name, n = f"{base}{n}", n + 1
    taken.add(name)
    return name


def escaped(name: str) -> str:
    return f"`{name}`" if name in SWIFT_KEYWORDS else name


def swift_string(text: str) -> str:
    return json.dumps(text, ensure_ascii=False)


# Model

@dataclass
class Property:
    wire: str
    name: str
    swift: str          # Swift type without the optional mark
    optional: bool
    schema: dict
    doc: str | None


@dataclass
class Named:
    """A Swift type the generator emits."""
    name: str
    kind: str           # "struct", "open-enum", "union", "alias"
    schema: dict
    doc: str | None = None
    properties: list[Property] = field(default_factory=list)
    values: list[tuple[str, str]] = field(default_factory=list)            # open enum: (case, raw)
    variants: list[tuple[str, str, str]] = field(default_factory=list)     # union: (case, raw tag, type)
    tag: str = ""                                                          # union discriminator property
    target: str = ""                                                       # alias target


class Generator:
    def __init__(self, contract: dict):
        self.contract = contract
        self.schemas: dict = contract.get("components", {}).get("schemas", {})
        self.names: dict[str, str] = {}          # schema key -> Swift name
        self.types: dict[str, Named] = {}        # Swift name -> type
        self.inline_names: dict[str, str] = {}   # canonical inline schema -> Swift name
        self.shared_inline: dict[str, str | None] = {}
        for key in self.schemas:
            name = upper_camel(key)
            if name in self.names.values():
                raise ContractError(f"two schemas map to the Swift name {name}")
            self.names[key] = name

    # Pass 1: find inline schemas that can share a short name.

    def collect_shared(self) -> None:
        seen: dict[str, set[str]] = {}
        uses: dict[str, int] = {}

        def visit(schema, hint: str):
            if not isinstance(schema, dict):
                return
            if self.needs_named_inline(schema):
                candidate = upper_camel(schema.get("title") or hint)
                seen.setdefault(candidate, set()).add(canonical(schema))
                uses[candidate] = uses.get(candidate, 0) + 1
            for key, value in schema.items():
                if key == "properties" and isinstance(value, dict):
                    for prop, sub in value.items():
                        visit(sub, prop)
                elif key in ("items", "additionalProperties"):
                    visit(value, hint + "Item" if key == "items" else hint + "Value")
                elif key in ("anyOf", "oneOf") and isinstance(value, list):
                    for sub in value:
                        visit(sub, hint)

        for key, schema in self.schemas.items():
            for prop, sub in schema.get("properties", {}).items():
                visit(sub, prop)
        top = set(self.names.values())
        # A short name only for a shape used in several places, all identical; a one-off is named after its
        # parent so that a later contract adding another shape with the same title cannot rename it.
        for candidate, shapes in seen.items():
            shared = len(shapes) == 1 and uses[candidate] > 1 and candidate not in top
            self.shared_inline[candidate] = candidate if shared else None

    def needs_named_inline(self, schema: dict) -> bool:
        if "$ref" in schema:
            return False
        if "oneOf" in schema and "discriminator" in schema:
            return True
        if schema.get("type") == "object" and "properties" in schema:
            return True
        if schema.get("type") == "string" and isinstance(schema.get("enum"), list):
            return True
        return False

    # Pass 2: build every type.

    def build(self) -> None:
        self.collect_shared()
        for key in sorted(self.schemas):
            self.declare(self.names[key], self.schemas[key])

    def declare(self, name: str, schema: dict) -> str:
        if name in self.types:
            return name
        doc = schema.get("description")
        if "oneOf" in schema and "discriminator" in schema:
            named = Named(name, "union", schema, doc)
            self.types[name] = named
            disc = schema["discriminator"]
            named.tag = disc["propertyName"]
            mapping = disc.get("mapping") or {}
            if not mapping:
                raise ContractError(f"{name}: a discriminator without a mapping")
            taken: set[str] = {"unknown"}
            for raw in sorted(mapping):
                ref = mapping[raw]
                named.variants.append((member_name(raw, taken), raw, self.ref_name(ref)))
            return name
        kind = schema.get("type")
        if kind == "string" and isinstance(schema.get("enum"), list):
            named = Named(name, "open-enum", schema, doc)
            self.types[name] = named
            taken: set[str] = {"known"}
            for raw in schema["enum"]:
                if not isinstance(raw, str):
                    raise ContractError(f"{name}: non-string enum value {raw!r}")
                named.values.append((member_name(raw, taken), raw))
            return name
        if kind == "object" and ("properties" in schema or schema.get("additionalProperties") is False):
            named = Named(name, "struct", schema, doc)
            self.types[name] = named
            required = set(schema.get("required", []))
            taken: set[str] = set()
            for wire, sub in schema.get("properties", {}).items():
                prop_name = member_name(wire, taken)
                swift, nullable = self.swift_type(sub, name, wire)
                named.properties.append(Property(wire, prop_name, swift, nullable or wire not in required,
                                                 sub, sub.get("description") if isinstance(sub, dict) else None))
            return name
        target, _ = self.swift_type(schema, name, "")
        named = Named(name, "alias", schema, doc, target=target)
        self.types[name] = named
        return name

    def ref_name(self, ref: str) -> str:
        if not ref.startswith(REF_PREFIX):
            raise ContractError(f"unsupported reference {ref}")
        key = ref[len(REF_PREFIX):]
        if key not in self.schemas:
            raise ContractError(f"dangling reference {ref}")
        return self.names[key]

    def inline_name(self, schema: dict, parent: str, prop: str) -> str:
        shape = canonical(schema)
        if shape in self.inline_names:
            return self.inline_names[shape]
        candidate = upper_camel(schema.get("title") or prop)
        name = self.shared_inline.get(candidate) or parent + upper_camel(prop)
        base, n = name, 2
        while name in self.types or name in self.names.values():
            name, n = f"{base}{n}", n + 1
        self.inline_names[shape] = name
        return self.declare(name, schema)

    def swift_type(self, schema, parent: str, prop: str) -> tuple[str, bool]:
        """(Swift type, allows null) for a property or item schema."""
        if schema is True or schema == {} or not isinstance(schema, dict):
            return "GatewayJSON", True
        if "$ref" in schema:
            return self.ref_name(schema["$ref"]), False
        if "anyOf" in schema:
            branches = schema["anyOf"]
            nullable = any(isinstance(b, dict) and b.get("type") == "null" for b in branches)
            rest = [b for b in branches if not (isinstance(b, dict) and b.get("type") == "null")]
            if not rest:
                return "GatewayJSON", True
            if len(rest) == 1:
                inner, inner_null = self.swift_type(rest[0], parent, prop)
                return inner, nullable or inner_null
            if all(isinstance(b, dict) and set(b) <= {"type", "title"} and b.get("type") in ("integer", "number")
                   for b in rest):
                return "Double", nullable
            return "GatewayJSON", True
        if self.needs_named_inline(schema):
            return self.inline_name(schema, parent, prop), False
        kind = schema.get("type")
        if isinstance(kind, list):
            rest = [k for k in kind if k != "null"]
            if len(rest) == 1:
                inner, _ = self.swift_type({**schema, "type": rest[0]}, parent, prop)
                return inner, "null" in kind
            return "GatewayJSON", True
        if kind == "string":
            return "String", False
        if kind == "integer":
            return "Int", False
        if kind == "number":
            return "Double", False
        if kind == "boolean":
            return "Bool", False
        if kind == "null":
            return "GatewayJSON", True
        if kind == "array":
            items = schema.get("items")
            if items is None:
                return "[GatewayJSON]", False
            inner, inner_null = self.swift_type(items, parent, prop + "Item")
            return (f"[{inner}?]" if inner_null and inner != "GatewayJSON" else f"[{inner}]"), False
        if kind == "object":
            extra = schema.get("additionalProperties", True)
            if isinstance(extra, dict) and extra:
                inner, inner_null = self.swift_type(extra, parent, prop + "Value")
                return (f"[String: {inner}?]" if inner_null and inner != "GatewayJSON" else f"[String: {inner}]"), False
            return "[String: GatewayJSON]", False
        if "const" in schema and isinstance(schema["const"], str):
            return "String", False
        return "GatewayJSON", True

    # Methods, questions and events

    def descriptors(self) -> tuple[list, list, list]:
        calls, questions, events = [], [], []
        for method in self.contract.get("methods", []):
            calls.append((method["name"], self.param_type(method), self.result_type(method), method.get("summary")))
        for method in self.contract.get("x-server-requests", []):
            questions.append((method["name"], self.param_type(method), self.result_type(method), method.get("summary")))
        for note in self.contract.get("x-notifications", []):
            params = note.get("params") or []
            schema = params[0]["schema"] if params else {"type": "object", "additionalProperties": False}
            if "$ref" in schema:
                payload = self.ref_name(schema["$ref"])
            else:
                name = upper_camel(note["name"]) + "Payload"
                if name in self.names.values():
                    raise ContractError(f"event payload name {name} clashes with a schema")
                payload = self.declare(name, schema)
            events.append((note["name"], payload, note.get("summary")))
        return calls, questions, events

    def param_type(self, method: dict) -> str:
        params = method.get("params") or []
        if len(params) != 1:
            raise ContractError(f"{method['name']}: expected one params object, found {len(params)}")
        return self.declared_or_named(params[0]["schema"], upper_camel(method["name"]) + "Params")

    def result_type(self, method: dict) -> str:
        result = method.get("result")
        if not result:
            return "GatewayJSON"
        return self.declared_or_named(result["schema"], upper_camel(method["name"]) + "Result")

    def declared_or_named(self, schema: dict, fallback: str) -> str:
        if "$ref" in schema:
            return self.ref_name(schema["$ref"])
        return self.declare(fallback, schema)


def canonical(schema) -> str:
    """The schema's shape without its annotations. Inside `properties` the keys are field names, so a field
    called "title" or "description" is kept."""
    def strip(value, names: bool = False):
        if isinstance(value, dict):
            return {k: strip(v, names=k == "properties" and not names)
                    for k, v in sorted(value.items()) if names or k not in ("title", "description")}
        if isinstance(value, list):
            return [strip(v) for v in value]
        return value
    return json.dumps(strip(schema), sort_keys=True)


# Swift output

HEADER = """// Generated by Tools/codegen/gateway_contract.py from Hermes's gateway contract. Do not edit.
// Contract: {title}, version {version}, sha256 {digest}.
"""


def render_type(t: Named) -> list[str]:
    out: list[str] = []
    if t.kind == "alias":
        out.append(f"    public typealias {t.name} = {t.target}")
        return out
    if t.kind == "open-enum":
        out.append(f"    public struct {t.name}: GatewayOpenEnum {{")
        out.append("        public let rawValue: String")
        out.append("        public init(rawValue: String) { self.rawValue = rawValue }")
        for case, raw in t.values:
            out.append(f"        public static let {escaped(case)} = Self(rawValue: {swift_string(raw)})")
        known = ", ".join(escaped(c) for c, _ in t.values)
        out.append(f"        public static let known: [Self] = [{known}]")
        out.append("    }")
        return out
    if t.kind == "union":
        out.append(f"    public enum {t.name}: Codable, Hashable, Sendable {{")
        for case, raw, swift in t.variants:
            out.append(f"        case {escaped(case)}({swift})")
        out.append("        /// A kind this build does not know, kept as it arrived.")
        out.append("        case unknown(GatewayJSON)")
        out.append("")
        out.append("        public init(from decoder: any Decoder) throws {")
        out.append("            let raw = try GatewayJSON(from: decoder)")
        out.append(f"            switch raw[{swift_string(t.tag)}]?.stringValue {{")
        for case, raw, swift in t.variants:
            out.append(f"            case {swift_string(raw)}: self = .{escaped(case)}(try {swift}(from: decoder))")
        out.append("            default: self = .unknown(raw)")
        out.append("            }")
        out.append("        }")
        out.append("")
        out.append("        public func encode(to encoder: any Encoder) throws {")
        out.append("            switch self {")
        for case, raw, swift in t.variants:
            out.append(f"            case .{escaped(case)}(let value): try value.encode(to: encoder)")
        out.append("            case .unknown(let raw): try raw.encode(to: encoder)")
        out.append("            }")
        out.append("        }")
        out.append("    }")
        return out
    out.append(f"    public struct {t.name}: Sendable, Hashable, Codable {{")
    for p in t.properties:
        out.append(f"        public var {escaped(p.name)}: {p.swift}{'?' if p.optional else ''}")
    if t.properties:
        out.append("")
        out.append("        enum CodingKeys: String, CodingKey {")
        for p in t.properties:
            raw = "" if p.name == p.wire else f" = {swift_string(p.wire)}"
            out.append(f"            case {escaped(p.name)}{raw}")
        out.append("        }")
        out.append("")
        args = ", ".join(
            f"{escaped(p.name)}: Optional<{p.swift}> = nil" if p.optional else f"{escaped(p.name)}: {p.swift}"
            for p in t.properties
        )
        out.append(f"        public init({args}) {{")
        for p in reversed(t.properties):
            out.append(f"            self.{p.name} = {escaped(p.name)}")
        out.append("        }")
    else:
        out.append("        public init() {}")
    out.append("    }")
    return out


def render_types(gen: Generator, header: str) -> dict[str, str]:
    names = sorted(gen.types)
    files: dict[str, str] = {}
    size = -(-len(names) // TYPE_FILES)
    for index in range(TYPE_FILES):
        chunk = names[index * size:(index + 1) * size]
        lines = [header, "import Foundation", "", "extension GatewayWire {"]
        for i, name in enumerate(chunk):
            if i:
                lines.append("")
            lines.extend(render_type(gen.types[name]))
        lines.append("}")
        files[f"GatewayWireTypes{index + 1}.swift"] = "\n".join(lines) + "\n"
    return files


def descriptor_names(entries, taken: set[str]) -> list[str]:
    return [member_name(entry[0], taken) for entry in entries]


def render_descriptors(gen: Generator, header: str, calls, questions, events) -> str:
    lines = [header, "import Foundation", "", "extension GatewayWire {"]
    lines.append("    /// Every method a client may call, by wire name.")
    lines.append("    public enum Calls {")
    call_names = descriptor_names(calls, {"all", "resultTypes"})
    for (wire, params, result, summary), name in zip(calls, call_names):
        lines.append(f"        public static let {escaped(name)} = GatewayCall<{params}, {result}>(name: {swift_string(wire)})")
    lines.append("        public static let all: [String] = [")
    lines.extend(f"            {swift_string(wire)}," for wire, *_ in calls)
    lines.append("        ]")
    lines.append("        /// Result type for each method name.")
    lines.append("        public static let resultTypes: [String: any GatewayWireValue.Type] = [")
    lines.extend(f"            {swift_string(wire)}: {result}.self," for wire, _, result, _ in calls)
    lines.append("        ]")
    lines.append("    }")
    lines.append("")
    lines.append("    /// Every question Hermes may ask the client (server-to-client requests), by wire name.")
    lines.append("    public enum Questions {")
    question_names = descriptor_names(questions, {"all", "paramTypes"})
    for (wire, params, result, summary), name in zip(questions, question_names):
        lines.append(f"        public static let {escaped(name)} = GatewayQuestion<{params}, {result}>(name: {swift_string(wire)})")
    lines.append("        public static let all: [String] = [")
    lines.extend(f"            {swift_string(wire)}," for wire, *_ in questions)
    lines.append("        ]")
    lines.append("        /// Params type for each question name.")
    lines.append("        public static let paramTypes: [String: any GatewayWireValue.Type] = [")
    lines.extend(f"            {swift_string(wire)}: {params}.self," for wire, params, _, _ in questions)
    lines.append("        ]")
    lines.append("    }")
    lines.append("")
    lines.append("    /// Every event type in the contract, with its payload type.")
    lines.append("    public enum Events {")
    event_names = descriptor_names(events, {"all", "payloadTypes"})
    for (wire, payload, summary), name in zip(events, event_names):
        lines.append(f"        public static let {escaped(name)} = GatewayEventKind<{payload}>(name: {swift_string(wire)})")
    lines.append("        public static let all: [String] = [")
    lines.extend(f"            {swift_string(wire)}," for wire, *_ in events)
    lines.append("        ]")
    lines.append("        /// Payload type for each event name, for decoding without knowing the event in advance.")
    lines.append("        public static let payloadTypes: [String: any GatewayWireValue.Type] = [")
    lines.extend(f"            {swift_string(wire)}: {payload}.self," for wire, payload, _ in events)
    lines.append("        ]")
    lines.append("    }")
    lines.append("}")
    return "\n".join(lines) + "\n"


# Samples for the decoding test

class Sampler:
    def __init__(self, gen: Generator):
        self.gen = gen
        self.by_name = gen.types

    def value(self, schema, full: bool, depth: int = 0):
        if depth > 80:
            raise ContractError("sample too deep; is there a cycle?")
        if schema is True or not isinstance(schema, dict) or schema == {}:
            return {"any": [1, "two", None, True]}
        if "$ref" in schema:
            return self.named(self.gen.ref_name(schema["$ref"]), full, depth + 1)
        if "anyOf" in schema:
            rest = [b for b in schema["anyOf"] if not (isinstance(b, dict) and b.get("type") == "null")]
            if not rest:
                return None
            if len(rest) > 1 and all(isinstance(b, dict) and b.get("type") in ("integer", "number") for b in rest):
                return 2.5
            return self.value(rest[0], full, depth + 1)
        if "oneOf" in schema and "discriminator" in schema:
            mapping = schema["discriminator"]["mapping"]
            raw = sorted(mapping)[0]
            sample = self.named(self.gen.ref_name(mapping[raw]), full, depth + 1)
            sample[schema["discriminator"]["propertyName"]] = raw
            return sample
        if "const" in schema:
            return schema["const"]
        if isinstance(schema.get("enum"), list):
            return schema["enum"][0]
        kind = schema.get("type")
        if isinstance(kind, list):
            kind = next((k for k in kind if k != "null"), "null")
        if kind == "string":
            return "sample"
        if kind == "integer":
            return 7
        if kind == "number":
            return 1.5
        if kind == "boolean":
            return True
        if kind == "null":
            return None
        if kind == "array":
            items = schema.get("items")
            return [self.value(items, full, depth + 1)] if items is not None else [{"any": 1}]
        if kind == "object":
            if "properties" in schema or schema.get("additionalProperties") is False:
                return self.object(schema, full, depth)
            extra = schema.get("additionalProperties", True)
            if isinstance(extra, dict) and extra:
                return {"key": self.value(extra, full, depth + 1)}
            return {"key": "value", "count": 3}
        return {"any": "value"}

    def object(self, schema: dict, full: bool, depth: int) -> dict:
        required = set(schema.get("required", []))
        out = {}
        for wire, sub in schema.get("properties", {}).items():
            if full or wire in required:
                out[wire] = self.value(sub, full, depth + 1)
        return out

    def named(self, name: str, full: bool, depth: int):
        t = self.by_name[name]
        if t.kind == "union":
            case, raw, swift = t.variants[0]
            sample = self.named(swift, full, depth + 1)
            sample[t.tag] = raw
            return sample
        return self.value(t.schema, full, depth)


def render_samples(gen: Generator, header: str) -> str:
    sampler = Sampler(gen)
    lines = [header, "@testable import NollieCore", "", "/// A full and a minimal sample of every generated wire type.",
             "let gatewayWireSamples: [GatewayWireSample] = ["]
    for name in sorted(gen.types):
        full = json.dumps(sampler.named(name, True, 0), sort_keys=True, ensure_ascii=False)
        minimal = json.dumps(sampler.named(name, False, 0), sort_keys=True, ensure_ascii=False)
        if '"#' in full or '"#' in minimal:
            raise ContractError(f"{name}: sample text would end the raw string")
        lines.append(f"    GatewayWireSample(name: {swift_string(name)}, type: GatewayWire.{name}.self,")
        lines.append(f"                      full: #\"{full}\"#,")
        lines.append(f"                      minimal: #\"{minimal}\"#),")
    lines.append("]")
    return "\n".join(lines) + "\n"


# Entry point

def generate(contract: dict, digest: str) -> dict[Path, str]:
    gen = Generator(contract)
    gen.build()
    calls, questions, events = gen.descriptors()
    info = contract.get("info", {})
    header = HEADER.format(title=info.get("title", "?"), version=info.get("version", "?"), digest=digest[:16])
    outputs: dict[Path, str] = {}
    for filename, text in render_types(gen, header).items():
        outputs[SOURCE_DIR / filename] = text
    outputs[SOURCE_DIR / "GatewayWireDescriptors.swift"] = render_descriptors(gen, header, calls, questions, events)
    outputs[SAMPLES_FILE] = render_samples(gen, header)
    return outputs


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    parser.add_argument("--check", action="store_true", help="fail when the checked-in files are out of date")
    args = parser.parse_args(argv)
    raw = args.contract.read_bytes()
    outputs = generate(json.loads(raw), hashlib.sha256(raw).hexdigest())
    stale = [path for path, text in outputs.items() if not path.exists() or path.read_text(encoding="utf-8") != text]
    extra = sorted(set(SOURCE_DIR.glob("*.swift")) - set(outputs)) if SOURCE_DIR.exists() else []
    if args.check:
        for path in stale + extra:
            print(f"out of date: {path.relative_to(ROOT)}", file=sys.stderr)
        return 1 if stale or extra else 0
    for path in extra:
        path.unlink()
    for path in stale:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(outputs[path], encoding="utf-8")
    print(f"{len(outputs)} files, {len(stale)} written, {len(extra)} removed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
