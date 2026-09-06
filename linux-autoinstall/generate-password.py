#!/usr/bin/env python3
import argparse
import re
import secrets
from pathlib import Path


def load_words(path: Path) -> list[str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise SystemExit(f"cannot read password word list {path}: {error}") from error

    words = []
    for line_number, line in enumerate(lines, 1):
        match = re.fullmatch(r"[1-6]{5}\t([a-z]+)", line)
        if match:
            words.append(match.group(1))
        elif not re.fullmatch(r"[1-6]{5}\t[a-z]+-[a-z]+", line):
            raise SystemExit(f"{path}:{line_number}: invalid EFF word-list entry")

    if len(words) < 7_700 or len(words) != len(set(words)):
        raise SystemExit(
            f"{path}: password word list must contain at least "
            "7700 unique alphabetic words"
        )
    return words


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--word-list", required=True, type=Path)
    args = parser.parse_args()

    words = load_words(args.word_list)
    selected = [secrets.choice(words).capitalize() for _ in range(3)]
    print("-".join((*selected, f"{secrets.randbelow(10_000):04d}")))


if __name__ == "__main__":
    main()
