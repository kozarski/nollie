"""Tests for the gateway contract generator."""

from __future__ import annotations

import hashlib
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gateway_contract as gen  # noqa: E402

REF = "#/components/schemas/"

# A small contract with one of each shape the real one uses.
CONTRACT = {
    "openrpc": "1.3.2",
    "info": {"title": "Tiny gateway", "version": "1"},
    "methods": [
        {"name": "ping", "params": [{"name": "params", "schema": {"$ref": REF + "Empty"}}],
         "result": {"name": "result", "schema": {"$ref": REF + "Pong"}}},
        {"name": "session.events.since", "params": [{"name": "params", "schema": {"$ref": REF + "SinceParams"}}],
         "result": {"name": "result", "schema": {"$ref": REF + "SinceResult"}}},
        {"name": "owner.set", "params": [{"name": "params", "schema": {"$ref": REF + "OwnerParams"}}],
         "result": {"name": "result", "schema": {"$ref": REF + "Pong"}}},
        {"name": "other.owner", "params": [{"name": "params", "schema": {"$ref": REF + "OtherOwnerParams"}}],
         "result": {"name": "result", "schema": {"$ref": REF + "Pong"}}},
    ],
    "x-server-requests": [
        {"name": "approval", "params": [{"name": "params", "schema": {"$ref": REF + "SinceParams"}}],
         "result": {"name": "result", "schema": {"$ref": REF + "Choice"}}},
    ],
    "x-notifications": [
        {"name": "gateway.ready", "params": [{"name": "payload", "schema": {"$ref": REF + "Pong"}}]},
        {"name": "message.start", "params": [{"name": "payload",
                                              "schema": {"type": "object", "additionalProperties": False}}]},
    ],
    "components": {"schemas": {
        "Empty": {"type": "object", "properties": {}, "additionalProperties": False},
        "Pong": {"type": "object", "properties": {"pong": {"type": "boolean"}}, "required": ["pong"]},
        "Choice": {"type": "string", "enum": ["once", "deny-all", "default", "1h"]},
        "SinceParams": {"type": "object", "required": ["session_id"], "properties": {
            "session_id": {"type": "string"},
            "last_seen": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": None},
        }},
        "SinceResult": {"type": "object", "required": ["events", "latest_seq", "epoch"], "properties": {
            "events": {"type": "array", "items": {"type": "object", "additionalProperties": True}},
            "latest_seq": {"type": "integer"},
            "epoch": {"type": "string"},
            "ratio": {"anyOf": [{"type": "integer"}, {"type": "number"}]},
            "mixed": {"anyOf": [{"type": "boolean"}, {"type": "string"}]},
            "counts": {"type": "object", "additionalProperties": {"type": "integer"}},
            "stage": {"type": "string", "enum": ["start", "end"], "title": "Stage"},
            "nested": {"type": "object", "properties": {"self": {"type": "string"}, "default": {"type": "integer"}}},
        }},
        "SessionOwner": {"type": "object", "required": ["type", "session_id"], "properties": {
            "type": {"const": "session", "type": "string"}, "session_id": {"type": "string"}}},
        "AccountOwner": {"type": "object", "required": ["type"], "properties": {
            "type": {"const": "account", "type": "string"}}},
        "OwnerParams": {"type": "object", "required": ["owner"], "properties": {"owner": {
            "title": "Owner", "oneOf": [{"$ref": REF + "SessionOwner"}, {"$ref": REF + "AccountOwner"}],
            "discriminator": {"propertyName": "type", "mapping": {"session": REF + "SessionOwner",
                                                                  "account": REF + "AccountOwner"}}}}},
        "OtherOwnerParams": {"type": "object", "properties": {"owner": {
            "title": "Owner", "oneOf": [{"$ref": REF + "SessionOwner"}, {"$ref": REF + "AccountOwner"}],
            "discriminator": {"propertyName": "type", "mapping": {"session": REF + "SessionOwner",
                                                                  "account": REF + "AccountOwner"}}}}},
        "_Scoped": {"type": "object", "properties": {"profile": {"type": "string"}}},
    }},
}


def run(contract=CONTRACT):
    raw = json.dumps(contract).encode()
    return gen.generate(contract, hashlib.sha256(raw).hexdigest())


def text_of(outputs, suffix: str) -> str:
    return "\n".join(text for path, text in outputs.items() if str(path).endswith(suffix))


class NamingTests(unittest.TestCase):
    def test_wire_names_become_swift_names(self):
        self.assertEqual(gen.lower_camel("session_id"), "sessionId")
        self.assertEqual(gen.lower_camel("displayName"), "displayName")
        self.assertEqual(gen.lower_camel("deny-all"), "denyAll")
        self.assertEqual(gen.lower_camel("1h"), "n1h")
        self.assertEqual(gen.lower_camel("URL"), "url")
        self.assertEqual(gen.upper_camel("session.events.since"), "SessionEventsSince")
        self.assertEqual(gen.upper_camel("_SessionScoped"), "SessionScoped")
        self.assertEqual(gen.upper_camel("Type"), "TypeKind")

    def test_member_names_are_unique_and_never_awkward(self):
        taken: set[str] = set()
        self.assertEqual(gen.member_name("foo_bar", taken), "fooBar")
        self.assertEqual(gen.member_name("fooBar", taken), "fooBar2")
        self.assertEqual(gen.member_name("self", taken), "selfValue")
        self.assertEqual(gen.escaped("default"), "`default`")
        self.assertEqual(gen.escaped("pong"), "pong")


class OutputTests(unittest.TestCase):
    def setUp(self):
        self.outputs = run()
        self.types = text_of(self.outputs, ".swift")
        self.descriptors = text_of(self.outputs, "GatewayWireDescriptors.swift")

    def test_structs_keep_wire_keys_and_mark_optional_fields(self):
        self.assertIn("public struct SinceParams: Sendable, Hashable, Codable {", self.types)
        self.assertIn("public var sessionId: String\n", self.types)
        self.assertIn("public var lastSeen: Int?\n", self.types)
        self.assertIn('case sessionId = "session_id"', self.types)
        self.assertIn("public init(sessionId: String, lastSeen: Optional<Int> = nil)", self.types)
        self.assertIn("            case pong\n", self.types)

    def test_unions_mixed_types_and_maps(self):
        self.assertIn("public var ratio: Double?", self.types)
        self.assertIn("public var mixed: GatewayJSON?", self.types)
        self.assertIn("public var counts: [String: Int]?", self.types)
        self.assertIn("public var events: [[String: GatewayJSON]]", self.types)

    def test_enums_stay_open(self):
        self.assertIn("public struct Choice: GatewayOpenEnum {", self.types)
        self.assertIn('public static let denyAll = Self(rawValue: "deny-all")', self.types)
        self.assertIn('public static let `default` = Self(rawValue: "default")', self.types)
        self.assertIn('public static let n1h = Self(rawValue: "1h")', self.types)

    def test_inline_shapes_share_a_name_only_when_identical(self):
        # Both owner properties are the same union, so they share the short name "Owner".
        self.assertEqual(self.types.count("public enum Owner: Codable, Hashable, Sendable {"), 1)
        self.assertIn("public var owner: Owner\n", self.types)
        self.assertIn("public var owner: Owner?\n", self.types)
        self.assertIn('case "session": self = .session(try SessionOwner(from: decoder))', self.types)
        self.assertIn("case unknown(GatewayJSON)", self.types)
        # A one-off inline object is named after its parent and property.
        self.assertIn("public struct SinceResultNested: Sendable, Hashable, Codable {", self.types)
        self.assertIn("public var selfValue: String?", self.types)
        self.assertIn('case selfValue = "self"', self.types)
        self.assertIn("public struct SinceResultStage: GatewayOpenEnum {", self.types)

    def test_descriptors(self):
        self.assertIn('public static let sessionEventsSince = GatewayCall<SinceParams, SinceResult>(name: "session.events.since")',
                      self.descriptors)
        self.assertIn('public static let approval = GatewayQuestion<SinceParams, Choice>(name: "approval")', self.descriptors)
        self.assertIn('public static let messageStart = GatewayEventKind<MessageStartPayload>(name: "message.start")',
                      self.descriptors)
        self.assertIn('"gateway.ready": Pong.self,', self.descriptors)
        self.assertIn("public struct MessageStartPayload: Sendable, Hashable, Codable {\n        public init() {}",
                      self.types)

    def test_samples_cover_every_type(self):
        samples = text_of(self.outputs, "GatewayWireSamples.swift")
        for name in ("SinceParams", "SinceResult", "Choice", "Owner", "SinceResultNested", "MessageStartPayload"):
            self.assertIn(f'GatewayWireSample(name: "{name}", type: GatewayWire.{name}.self,', samples)
        self.assertIn('minimal: #"{"session_id": "sample"}"#', samples)
        self.assertIn('"type": "account"', samples)  # the union sample sets its tag

    def test_output_is_deterministic(self):
        self.assertEqual(run(), self.outputs)

    def test_comments_and_text_carry_no_contract_prose(self):
        contract = json.loads(json.dumps(CONTRACT))
        contract["methods"][0]["summary"] = "Probe text that must not be copied."
        contract["components"]["schemas"]["Pong"]["description"] = "Schema prose that must not be copied."
        for text in run(contract).values():
            self.assertNotIn("must not be copied", text)


class ErrorTests(unittest.TestCase):
    def test_dangling_reference_is_refused(self):
        broken = json.loads(json.dumps(CONTRACT))
        broken["methods"][0]["result"]["schema"] = {"$ref": REF + "Missing"}
        with self.assertRaises(gen.ContractError):
            run(broken)

    def test_two_params_are_refused(self):
        broken = json.loads(json.dumps(CONTRACT))
        broken["methods"][0]["params"].append({"name": "extra", "schema": {"type": "string"}})
        with self.assertRaises(gen.ContractError):
            run(broken)


@unittest.skipUnless(gen.DEFAULT_CONTRACT.exists(), "Hermes's contract is not on this machine")
class CheckedInFilesTests(unittest.TestCase):
    def test_generated_files_match_the_contract(self):
        self.assertEqual(gen.main(["--check"]), 0, "run python3 Tools/codegen/gateway_contract.py")


if __name__ == "__main__":
    unittest.main()
