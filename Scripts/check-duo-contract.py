#!/usr/bin/env python3
"""Checks HydroCore's Duo wire models against the frozen contract.

The Duo v2 server's wire contract is frozen at the tag `contract-v1` of HydroDrop-Server
(`openapi.json`, version 1.0.0). HydroCore's `DuoWire.swift` and `DuoErrors.swift` are written
against it by hand, so this script reads both and fails on any difference that would make a
real response fail to decode or a real request be refused:

  - every schema the client uses has a Swift type, with the same property names (a Swift
    property `deviceId` is the contract's `device_id`);
  - a property is optional in Swift exactly when the schema does not require it, or requires
    it but allows `null`;
  - `DuoErrorCode` lists exactly the contract's error codes, and the string enums the client
    reads (ended_by, a rejected row's reason, an invite's purpose, a member's tier, a role, a
    duo's state) are all there;
  - a `DuoWireField` (absent, null or a value) stands only on a property the schema lets be null,
    or on one `FIELD_NULL_DROPPED` names because the encoder writes a null for it as nothing.

What it does NOT check, and a reviewer has to: the types of properties; what a custom
`encode(to:)` writes (it reads declarations, not bodies); the error envelope's own keys and
`details`; the methods, paths, status codes and headers of the 19 operations, the idempotent
set and the attestation actions (`DuoTransport` and the API client's tests own those); and the
`Error` and `HealthResponse` schemas. Its "required but nullable means optional in Swift" rule
is right for a response and, for a request, holds only because `NULLABLE_REQUIRED` lists the two
request fields by hand. A request body is best proved by encoding it and validating the bytes
against the server's own schemas, which this script does not do.

Usage:
    Scripts/check-duo-contract.py [--server ~/Developer/HydroDrop-Server] [--openapi FILE]

With neither option it reads `contract-v1:openapi.json` from ~/Developer/HydroDrop-Server.
Exit status 0 when everything agrees, 1 when anything does not.
"""
import argparse
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WIRE = os.path.join(ROOT, "HydroCore/Sources/HydroCore/DuoWire.swift")
ERRORS = os.path.join(ROOT, "HydroCore/Sources/HydroCore/DuoErrors.swift")
MODELS = os.path.join(ROOT, "HydroCore/Sources/HydroCore/DuoModels.swift")
STATE = os.path.join(ROOT, "HydroCore/Sources/HydroCore/DuoState.swift")

SCHEMA_TO_TYPE = {
    "CreateDeviceRequest": "DuoWireCreateDeviceRequest", "CreateDeviceResponse": "DuoWireCreateDeviceResponse",
    "AttestChallengeResponse": "DuoWireAttestChallenge", "RotateSecretResponse": "DuoWireRotateResponse",
    "Member": "DuoWireMember", "GetMeResponse": "DuoWireGetMeResponse", "UpdateMeRequest": "DuoWireUpdateMeRequest",
    "DeleteMeRequest": "DuoWireDeleteMeRequest", "RegisterPushRequest": "DuoWireRegisterPushRequest",
    "StatusIn": "DuoWireStatusIn", "CreateDuoRequest": "DuoWireCreateDuoRequest", "CreateDuoResponse": "DuoWireCreateDuoResponse",
    "CreateInviteRequest": "DuoWireCreateInviteRequest", "Invite": "DuoWireInvite", "PeekInviteRequest": "DuoWirePeekRequest",
    "PeekInviteResponse": "DuoWirePeekResponse", "RedeemInviteRequest": "DuoWireRedeemRequest",
    "ReconnectRequest": "DuoWireReconnectRequest", "ReconnectResponse": "DuoWireReconnectResponse",
    "DuoHeader": "DuoWireHeader", "Changes": "DuoWireChanges", "ChangesWithResult": "DuoWireChangesWithResult",
    "PutStatusesRequest": "DuoWirePutStatusesRequest", "StatusRow": "DuoWireStatusRow", "Nudge": "DuoWireNudge",
    "Handled": "DuoWireHandled", "Rejected": "DuoWireRejected", "SendNudgeRequest": "DuoWireSendNudgeRequest",
    "SendNudgeResponse": "DuoWireSendNudgeResponse", "LeaveDuoResponse": "DuoWireLeaveResponse",
    "EmptyRequest": "DuoWireEmptyRequest",
}
# Required by the schema, nullable, and always written by the client (as null when empty).
NULLABLE_REQUIRED = {("CreateDuoRequest", "display_name"), ("RedeemInviteRequest", "display_name")}
# A `DuoWireField` on a property the schema does not let be null: PATCH /me's `skin` and
# `terms_version`. The encoder writes a `.null` for either as nothing (DuoWireUpdateMeRequest.encode),
# because the server refuses a null there with `400 schema`.
FIELD_NULL_DROPPED = {("UpdateMeRequest", "skin"), ("UpdateMeRequest", "terms_version")}


def nullable(prop):
    if isinstance(prop.get("type"), list) and "null" in prop["type"]:
        return True
    return any(isinstance(a, dict) and a.get("type") == "null" for a in prop.get("anyOf", []))


def snake(name):
    return re.sub(r"(?<=[a-z0-9])([A-Z])", r"_\1", name).lower()


def swift_types(source):
    types, current = {}, None
    for line in source.split("\n"):
        m = re.match(r"^public struct (\w+)", line)
        if m:
            current = m.group(1)
            types[current] = {}
            continue
        if re.match(r"^(public )?(enum|extension|private extension|struct|final class|class)\b", line):
            current = None
        if current:
            m = re.match(r"^    public var (\w+): ([^\n={]+?)\s*(=|\{|$)", line)
            if m and "{" not in line.split(":", 1)[1].split("//")[0]:
                types[current][snake(m.group(1))] = m.group(2).strip()
    return types


def swift_enum_cases(source, name):
    start = source.find(f"public enum {name}")
    if start < 0:
        return None
    end = source.find("\n}\n", start)
    body = source[start:end]
    cases = set()
    for m in re.finditer(r"^    case (\w+)(?: = \"([a-z_]+)\")?$", body, re.M):
        cases.add(m.group(2) or m.group(1))
    return cases


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", default=os.path.expanduser("~/Developer/HydroDrop-Server"))
    parser.add_argument("--openapi")
    args = parser.parse_args()
    if args.openapi:
        spec = json.load(open(args.openapi))
    else:
        text = subprocess.run(["git", "-C", args.server, "show", "contract-v1:openapi.json"], capture_output=True, text=True, check=True).stdout
        spec = json.loads(text)
    schemas = spec["components"]["schemas"]
    wire = open(WIRE).read()
    swift = swift_types(wire)
    problems = []

    def check(schema_name, schema, type_name):
        if type_name not in swift:
            problems.append(f"missing Swift type {type_name} for {schema_name}")
            return
        props, required, have = schema.get("properties", {}), set(schema.get("required", [])), swift[type_name]
        for p in props:
            if p not in have:
                problems.append(f"{type_name}: schema property {p} has no Swift property")
                continue
            optional = have[p].endswith("?") or have[p].startswith("DuoWireField<")
            if have[p].startswith("DuoWireField<") and not nullable(props[p]) and (schema_name, p) not in FIELD_NULL_DROPPED:
                problems.append(f"{type_name}.{p}: a DuoWireField can write null, which the schema does not allow here")
            if (schema_name, p) in NULLABLE_REQUIRED:
                if not optional:
                    problems.append(f"{type_name}.{p}: required-nullable should be optional in Swift")
                continue
            if p in required and optional and not nullable(props[p]):
                problems.append(f"{type_name}.{p}: required and not nullable in the schema but optional in Swift")
            if p in required and not optional and nullable(props[p]):
                problems.append(f"{type_name}.{p}: required and nullable in the schema but not optional in Swift")
            if p not in required and not optional:
                problems.append(f"{type_name}.{p}: optional in the schema but not in Swift")
        if schema_name != "ChangesWithResult":
            for p in have:
                if p not in props:
                    problems.append(f"{type_name}.{p}: Swift property not in the schema {schema_name}")

    for schema_name, type_name in SCHEMA_TO_TYPE.items():
        schema = schemas[schema_name]
        if schema_name == "ChangesWithResult":
            result = {k: v for k, v in schema["properties"].items() if k in ("accepted", "unchanged", "rejected")}
            check(schema_name, {"properties": result, "required": list(result)}, type_name)
            if "changes" not in swift.get(type_name, {}):
                problems.append("DuoWireChangesWithResult has no `changes`")
            continue
        check(schema_name, schema, type_name)
    gm = schemas["GetMeResponse"]["properties"]
    check("Limits", gm["limits"], "DuoWireLimits")
    check("MinClient", gm["min_client"], "DuoWireMinClient")
    check("Device", gm["devices"]["items"], "DuoWireDevice")
    check("HeaderInvite", schemas["DuoHeader"]["properties"]["invite"], "DuoWireHeaderInvite")

    codes = set(schemas["Error"]["properties"]["error"]["properties"]["code"]["enum"])
    have_codes = swift_enum_cases(open(ERRORS).read(), "DuoErrorCode") or set()
    if codes != have_codes:
        problems.append(f"DuoErrorCode differs from the contract: missing {sorted(codes - have_codes)}, extra {sorted(have_codes - codes)}")

    ended_by = set(schemas["DuoHeader"]["properties"]["ended_by"]["anyOf"][0]["enum"])
    have_ended = (swift_enum_cases(open(MODELS).read(), "DuoEndedBy") or set()) - {"unknown"}
    if ended_by != have_ended:
        problems.append(f"DuoEndedBy differs from ended_by: missing {sorted(ended_by - have_ended)}, extra {sorted(have_ended - ended_by)}")

    reasons = set(schemas["Rejected"]["properties"]["reason"]["enum"])
    have_reasons = (swift_enum_cases(wire, "DuoWireRejectReason") or set()) - {"unknown"}
    if reasons != have_reasons:
        problems.append(f"DuoWireRejectReason differs from the contract: missing {sorted(reasons - have_reasons)}, extra {sorted(have_reasons - reasons)}")

    purposes = set(schemas["CreateInviteRequest"]["properties"]["purpose"]["enum"])
    have_purposes = swift_enum_cases(wire, "DuoWireInvitePurpose") or set()
    if purposes != have_purposes:
        problems.append(f"DuoWireInvitePurpose differs from the contract: missing {sorted(purposes - have_purposes)}, extra {sorted(have_purposes - purposes)}")

    # The string enums a decode would otherwise fail on, or quietly misread, if a value went missing.
    state_source = open(STATE).read()
    models_source = open(MODELS).read()
    for label, values, have in (
        ("DuoTier", set(schemas["Member"]["properties"]["tier"]["enum"]), swift_enum_cases(models_source, "DuoTier")),
        ("DuoRole", set(schemas["DuoHeader"]["properties"]["my_role"]["enum"]), swift_enum_cases(state_source, "DuoRole")),
        ("DuoWireDuoState", set(schemas["DuoHeader"]["properties"]["state"]["enum"]), swift_enum_cases(wire, "DuoWireDuoState")),
    ):
        have = have or set()
        if values != have:
            problems.append(f"{label} differs from the contract: missing {sorted(values - have)}, extra {sorted(have - values)}")

    if problems:
        print("\n".join(problems))
        print(f"{len(problems)} difference(s) from contract-v1")
        sys.exit(1)
    print(f"DuoWire.swift matches contract-v1: {len(SCHEMA_TO_TYPE) + 4} schemas, {len(codes)} error codes")


main()
