#!/usr/bin/env python3
"""Proves that a build with Duo Streaks v2 switched off has no Duo in it that can be reached.

Duo v2 compiles in only when the Swift condition `DUO_V2` is set (decision D5), so a release
from this branch without it must be the app `main` ships. The compiler proves part of that on
its own: a flag-off build that names a type defined only under `#if DUO_V2` fails to compile.
What it cannot see is code that compiles either way and still reaches Duo, above all a call
into HydroCore's Duo rules and wire types, which are public and always built (they are pure
and shared with the widget and the Watch app). This script reads the tree and fails on:

  (a) a Duo file that is not wholly wrapped. Every Swift file in a folder named `Duo`, or
      whose name starts with `Duo`, under the app, widget, Watch app and test folders
      (HydroDrop/Duo/, HydroDrop/Views/Duo*.swift, HydroDrop/Shared/Duo*.swift,
      HydroDropWidgets/DuoWidget.swift, HydroDropTests/Duo*.swift and
      HydroDropTests/Support/Duo*.swift among them) must start, after comments and blank
      lines, with an `#if` whose condition holds only when DUO_V2 does (`#if DUO_V2` or
      `#if DUO_V2 && DEBUG`), end with that `#if`'s own `#endif`, and have no `#else` or
      `#elseif` of it in between, since that branch is what a flag-off build compiles;

  (b) a Duo name outside such a region in any Swift file of those folders: an identifier
      that contains `Duo` followed by a capital letter (`DuoStore`, `DuoStreak.isDayKey`,
      `pendingDuoLink`), which covers the plan's `\\bDuo[A-Z]\\w*` and `DuoStore` rules and
      also a Duo property added to a shared type without its `#if`. Comments are not code
      and are skipped; string literals are code here, so a `"DuoWidget"` kind or an
      interpolated `\\(DuoStore.shared)` counts. `#if`, `#elseif`, `#else` and `#endif` are
      tracked with their nesting, and a line counts as inside only when the conditions of
      every branch around it cannot all be true with DUO_V2 off: the `#else` of `#if DUO_V2`
      is outside, the `#else` of `#if !DUO_V2` is inside, `#if DUO_V2 || DEBUG` is outside.
      `LegacyDuoCleanup`, the retired iCloud version's cleanup that runs on every build,
      and the `legacyDuoCleanup.` defaults keys it writes are the only names allowed;

  (c) `DuoAPIClient` named anywhere in the app, widget or Watch app folders outside
      HydroDrop/Duo/, in any text file, comments included. It is the one class that talks
      to the server, and the plan's exit criterion is that nothing outside the Duo folder
      names it. HydroCore, the tests, CLAUDE.md, this script and preflight may name it and
      are not read.

Files are read from disk, not from git: XcodeGen compiles every file in a source folder,
tracked or not, so an untracked file is exactly as reachable as a committed one. HydroCore is
not read at all: its Duo rules are pure, public and always compiled, by design.

What it does NOT see: a bare regular-expression literal (`/.../`) holding a quote or `//`
can mislead the comment scanner (`#/.../#` literals are handled); a Duo symbol reached
without its name (through a protocol, a generic or a string key read at run time); and a
Duo source added to the widget or Watch target from a folder this script does not read.

Usage:
    Scripts/check-duo-gating.py [REPO]

REPO defaults to the checkout this script is in. Exit status 0 when nothing is found, 1 with
one `path:line: problem` line for each finding, 2 when the folder is not a HydroDrop checkout.
"""
import itertools
import os
import re
import sys

# The folders whose Swift a build compiles into the app, the widget, the Watch app or the
# test bundles. HydroCore is left out on purpose (see the docstring).
SWIFT_ROOTS = ["HydroDrop", "HydroDropWidgets", "HydroDrop Watch App", "HydroDropTests",
               "HydroDropScreenshotUITests"]
# (c) reads these, minus HydroDrop/Duo/, the folder DuoAPIClient lives in.
CLIENT_ROOTS = ["HydroDrop", "HydroDropWidgets", "HydroDrop Watch App"]
CLIENT_EXEMPT = "HydroDrop/Duo/"
SKIP_DIRS = {".git", ".build", "build", "DerivedData", "xcuserdata", ".swiftpm"}

DUO_NAME = re.compile(r"[A-Za-z0-9_]*Duo[A-Z][A-Za-z0-9_]*")
IDENTIFIER = re.compile(r"(?<![A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*")
# The retired iCloud Duo's cleanup, which every build runs, and the defaults keys it owns.
ALLOWED_NAMES = {"LegacyDuoCleanup", "legacyDuoCleanup"}
FLAG = "DUO_V2"


# ---------------------------------------------------------------------------------------------
# Swift source without its comments
# ---------------------------------------------------------------------------------------------

def strip_comments(source):
    """Returns `(lines, starts_in_code)`: the source with every comment replaced by spaces
    (so columns and line numbers stay), split into lines, and for each line whether it begins
    in plain code rather than inside a block comment, a multi-line string or an
    interpolation. String literals are kept as they are, interpolations included, so a
    comment marker inside a string (`"https://..."`) is never taken for a comment."""
    out = []
    i, n = 0, len(source)
    # Each frame: ("code", parens) where parens is None for the file's own code and a depth for
    # the code of an interpolation; ("string", closing, escape); ("block", depth).
    stack = [("code", None)]
    line_starts_in_code = [True]

    def emit(text):
        for ch in text:
            out.append(ch)
            if ch == "\n":
                line_starts_in_code.append(len(stack) == 1)

    while i < n:
        frame = stack[-1]
        kind = frame[0]
        if kind == "code":
            if source.startswith("//", i):
                end = source.find("\n", i)
                end = n if end == -1 else end
                emit(" " * (end - i))
                i = end
                continue
            if source.startswith("/*", i):
                stack.append(("block", 1))
                emit("  ")
                i += 2
                continue
            if source[i] in '#"':
                hashes = 0
                while i + hashes < n and source[i + hashes] == "#":
                    hashes += 1
                j = i + hashes
                if j < n and source[j] == '"':
                    if source.startswith('"""', j):
                        opening, closing = hashes + 3, '"""' + "#" * hashes
                    else:
                        opening, closing = hashes + 1, '"' + "#" * hashes
                    stack.append(("string", closing, "\\" + "#" * hashes, closing.startswith('"""')))
                    emit(source[i:i + opening])
                    i += opening
                    continue
                if hashes and j < n and source[j] == "/":
                    # An extended regular-expression literal, #/.../#: its text is not code.
                    end = source.find("/" + "#" * hashes, j + 1)
                    end = n if end == -1 else end + 1 + hashes
                    emit("".join(ch if ch == "\n" else " " for ch in source[i:end]))
                    i = end
                    continue
            ch = source[i]
            if frame[1] is not None:
                if ch == "(":
                    stack[-1] = ("code", frame[1] + 1)
                elif ch == ")":
                    if frame[1] == 0:
                        stack.pop()
                        emit(ch)
                        i += 1
                        continue
                    stack[-1] = ("code", frame[1] - 1)
            emit(ch)
            i += 1
        elif kind == "block":
            if source.startswith("/*", i):
                stack[-1] = ("block", frame[1] + 1)
                emit("  ")
                i += 2
            elif source.startswith("*/", i):
                if frame[1] == 1:
                    stack.pop()
                else:
                    stack[-1] = ("block", frame[1] - 1)
                emit("  ")
                i += 2
            else:
                emit("\n" if source[i] == "\n" else " ")
                i += 1
        else:  # a string literal
            _, closing, escape, multiline = frame
            if source.startswith(escape, i) and i + len(escape) < n:
                after = i + len(escape)
                if source[after] == "(":
                    stack.append(("code", 0))
                    emit(source[i:after + 1])
                    i = after + 1
                else:
                    emit(source[i:after + 1])
                    i = after + 1
                continue
            if source.startswith(closing, i):
                stack.pop()
                emit(closing)
                i += len(closing)
                continue
            if not multiline and source[i] == "\n":
                # An unterminated single-line string: Swift rejects it, so give up on it here.
                stack.pop()
            emit(source[i])
            i += 1
    lines = "".join(out).split("\n")
    return lines, line_starts_in_code[:len(lines)]


# ---------------------------------------------------------------------------------------------
# #if conditions
# ---------------------------------------------------------------------------------------------

DIRECTIVE = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")
COND_TOKEN = re.compile(r"\s*(&&|\|\||!|\(|\)|[A-Za-z_][A-Za-z0-9_]*(?:\s*\([^()]*\))?)")


class Unreadable(Exception):
    pass


def parse_condition(text):
    """A condition as a function of the atoms' truth values (a dict), and the atoms it names.
    A condition that cannot be read becomes one opaque atom, which may be true or false, so an
    unreadable `#if` is never taken for one that guarantees DUO_V2."""
    text = text.strip()
    tokens, pos = [], 0
    try:
        while pos < len(text):
            match = COND_TOKEN.match(text, pos)
            if not match:
                raise Unreadable(text)
            tokens.append(re.sub(r"\s+", "", match.group(1)))
            pos = match.end()
            while pos < len(text) and text[pos].isspace():
                pos += 1
        if not tokens:
            raise Unreadable(text)
        index = [0]

        def peek():
            return tokens[index[0]] if index[0] < len(tokens) else None

        def take():
            index[0] += 1
            return tokens[index[0] - 1]

        def parse_or():
            left = parse_and()
            while peek() == "||":
                take()
                right = parse_and()
                left = (lambda a, b: lambda env: a(env) or b(env))(left, right)
            return left

        def parse_and():
            left = parse_unary()
            while peek() == "&&":
                take()
                right = parse_unary()
                left = (lambda a, b: lambda env: a(env) and b(env))(left, right)
            return left

        def parse_unary():
            if peek() == "!":
                take()
                inner = parse_unary()
                return lambda env: not inner(env)
            return parse_primary()

        def parse_primary():
            token = take() if peek() is not None else None
            if token == "(":
                inner = parse_or()
                if take() != ")":
                    raise Unreadable(text)
                return inner
            if token in (None, ")", "&&", "||"):
                raise Unreadable(text)
            if token == "true":
                return lambda env: True
            if token == "false":
                return lambda env: False
            return lambda env, name=token: env[name]

        evaluate = parse_or()
        if peek() is not None:
            raise Unreadable(text)
        atoms = {t for t in tokens if t not in ("&&", "||", "!", "(", ")", "true", "false")}
        return evaluate, atoms
    except (Unreadable, IndexError):
        name = "?" + text
        return (lambda env: env[name]), {name}


def requires_flag(conditions):
    """Whether code under every one of `conditions` (each `(evaluate, atoms)`) can only be
    compiled with DUO_V2 set: no way of setting the other atoms makes them all true with it
    off. Twelve atoms at most are tried; past that the answer is no, which errs towards a
    finding."""
    atoms = set()
    for _, names in conditions:
        atoms |= names
    others = sorted(atoms - {FLAG})
    if len(others) > 12:
        return False
    for values in itertools.product([False, True], repeat=len(others)):
        env = dict(zip(others, values))
        env[FLAG] = False
        if all(evaluate(env) for evaluate, _ in conditions):
            return False
    return True


def negate(condition):
    evaluate, atoms = condition
    return (lambda env: not evaluate(env)), atoms


def conjunction(conditions):
    atoms = set()
    for _, names in conditions:
        atoms |= names
    return (lambda env: all(evaluate(env) for evaluate, _ in conditions)), atoms


# ---------------------------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------------------------

def is_duo_file(rel):
    parts = rel.split("/")
    return parts[-1].startswith("Duo") or "Duo" in parts[:-1]


def walk(repo, roots, suffix=None):
    found = []
    for root in roots:
        top = os.path.join(repo, root)
        if not os.path.isdir(top):
            continue
        for directory, subdirs, files in os.walk(top):
            subdirs[:] = sorted(d for d in subdirs if d not in SKIP_DIRS and not d.endswith(".xcodeproj"))
            for name in sorted(files):
                if suffix is None or name.endswith(suffix):
                    found.append(os.path.relpath(os.path.join(directory, name), repo).replace(os.sep, "/"))
    return found


def check_swift_file(rel, source):
    """Findings (a) and (b) for one file, as `(line, message)` pairs."""
    findings = []
    lines, in_code = strip_comments(source)
    # Each open #if: [the conditions of its earlier branches, this branch's own, its line].
    frames = []
    inside = False  # whether the lines under the current branches need DUO_V2
    duo_file = is_duo_file(rel)
    wrapper_line = None  # the line of a Duo file's opening `#if DUO_V2`
    wrapper_closed_at = None  # the line of that `#if`'s own `#endif`, once seen
    seen_code = False
    reported_trailing = False

    def recompute():
        conditions = [conjunction([negate(c) for c in earlier] + [own]) for earlier, own, _ in frames]
        return bool(conditions) and requires_flag(conditions)

    for number, (text, starts_in_code) in enumerate(zip(lines, in_code), start=1):
        if not text.strip():
            continue
        directive = DIRECTIVE.match(text) if starts_in_code else None
        if duo_file and not seen_code:
            if directive and directive.group(1) == "if" and requires_flag([parse_condition(directive.group(2))]):
                wrapper_line = number
            else:
                findings.append((number, "a Duo file must start with `#if DUO_V2` (or `#if DUO_V2 && DEBUG`), "
                                         "so a build without the flag compiles none of it"))
        elif duo_file and wrapper_closed_at is not None and not reported_trailing:
            findings.append((number, f"this comes after the `#endif` on line {wrapper_closed_at} that closes the "
                                     "file's `#if DUO_V2`, so a build without the flag compiles it"))
            reported_trailing = True
        seen_code = True
        if directive:
            word, rest = directive.group(1), directive.group(2)
            if word == "if":
                frames.append([[], parse_condition(rest), number])
            elif not frames:
                findings.append((number, f"`#{word}` with no `#if` before it"))
                continue
            elif word in ("elseif", "else"):
                frame = frames[-1]
                frame[0].append(frame[1])
                frame[1] = parse_condition(rest) if word == "elseif" else ((lambda env: True), set())
                if frame[2] == wrapper_line and len(frames) == 1:
                    findings.append((number, f"an `#{word}` of the file's `#if DUO_V2` is what a build without "
                                             "the flag compiles; a Duo file has none"))
            else:
                frame = frames.pop()
                if frame[2] == wrapper_line and not frames:
                    wrapper_closed_at = number
            inside = recompute()
            continue
        if inside:
            continue
        for match in IDENTIFIER.finditer(text):
            name = match.group(0)
            if DUO_NAME.fullmatch(name) and name not in ALLOWED_NAMES:
                findings.append((number, f"`{name}` is outside `#if DUO_V2`, so a build without the flag compiles it"))
    if frames:
        findings.append((frames[-1][2], "this `#if` has no `#endif`"))
    return findings


def check_client_name(repo):
    """(c): `DuoAPIClient` outside HydroDrop/Duo/ in the app, widget and Watch folders."""
    findings = []
    for rel in walk(repo, CLIENT_ROOTS):
        if rel.startswith(CLIENT_EXEMPT):
            continue
        try:
            with open(os.path.join(repo, rel), "rb") as handle:
                data = handle.read()
        except OSError:
            continue
        if b"\0" in data[:8192]:
            continue
        for number, line in enumerate(data.decode("utf-8", "replace").split("\n"), start=1):
            if "DuoAPIClient" in line:
                findings.append((rel, number, "names `DuoAPIClient`, which only HydroDrop/Duo/ may"))
    return findings


def run(repo):
    findings = []
    duo_files = 0
    swift_files = walk(repo, SWIFT_ROOTS, ".swift")
    for rel in swift_files:
        with open(os.path.join(repo, rel), encoding="utf-8", errors="replace") as handle:
            source = handle.read()
        if is_duo_file(rel):
            duo_files += 1
        for number, message in check_swift_file(rel, source):
            findings.append((rel, number, message))
    findings += check_client_name(repo)
    return findings, duo_files, len(swift_files)


def main(argv):
    repo = os.path.abspath(argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    if not os.path.isdir(os.path.join(repo, "HydroDrop")):
        print(f"not a HydroDrop checkout: {repo}", file=sys.stderr)
        return 2
    findings, duo_files, swift_files = run(repo)
    for rel, number, message in sorted(findings):
        print(f"{rel}:{number}: {message}")
    if findings:
        print(f"Duo gating: {len(findings)} problem(s) in {swift_files} Swift files ({duo_files} Duo files)")
        return 1
    print(f"Duo gating holds: {duo_files} Duo files wholly inside #if DUO_V2, no Duo name outside it "
          f"in {swift_files - duo_files} other Swift files, and no DuoAPIClient outside HydroDrop/Duo/")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
