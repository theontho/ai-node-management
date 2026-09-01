"""Deterministic coding tasks for the agent CLI benchmark."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class BenchmarkTask:
    name: str
    language: str
    difficulty: str
    summary: str
    prompt: str
    files: dict[str, str]
    allowed_changes: frozenset[str]
    protected_files: frozenset[str]
    test_command: tuple[str, ...]
    hidden_command: tuple[str, ...]


ATOMIC_TASKS = (
    BenchmarkTask(
        name="python-clamp",
        language="Python",
        difficulty="easy",
        summary="Localized boundary-condition bug",
        prompt=(
            "Fix the bug in math_utils.py so every test in test_math_utils.py "
            "passes. Modify only math_utils.py, do not modify the tests, run "
            "`python3 -m unittest discover -q`, and stop when the tests pass."
        ),
        files={
            "math_utils.py": """\
def clamp(value, lower, upper):
    return max(lower, min(lower, value))
""",
            "test_math_utils.py": """\
import unittest

from math_utils import clamp


class ClampTests(unittest.TestCase):
    def test_value_inside_range(self):
        self.assertEqual(clamp(5, 0, 10), 5)

    def test_value_below_range(self):
        self.assertEqual(clamp(-2, 0, 10), 0)

    def test_value_above_range(self):
        self.assertEqual(clamp(12, 0, 10), 10)


if __name__ == "__main__":
    unittest.main()
""",
        },
        allowed_changes=frozenset({"math_utils.py"}),
        protected_files=frozenset({"test_math_utils.py"}),
        test_command=("python3", "-m", "unittest", "discover", "-q"),
        hidden_command=(
            "python3",
            "-c",
            (
                "from math_utils import clamp; "
                "assert clamp(0, 0, 0) == 0; "
                "assert clamp(2.5, 1.5, 3.5) == 2.5; "
                "assert clamp(-9, -4, -1) == -4"
            ),
        ),
    ),
    BenchmarkTask(
        name="python-inventory",
        language="Python",
        difficulty="medium",
        summary="State mutation and input-invariant repair",
        prompt=(
            "Fix Inventory.reserve in inventory.py. A reservation may consume "
            "all remaining stock, invalid quantities must raise ValueError "
            "without changing stock, and insufficient stock must raise "
            "ValueError. Modify only inventory.py, leave tests unchanged, run "
            "`python3 -m unittest discover -q`, and stop when they pass."
        ),
        files={
            "inventory.py": """\
class Inventory:
    def __init__(self, stock):
        self.stock = dict(stock)

    def reserve(self, sku, quantity):
        available = self.stock.get(sku, 0)
        self.stock[sku] = available - quantity
        if quantity <= 0:
            raise ValueError("quantity must be positive")
        if quantity >= available:
            raise ValueError("insufficient stock")
        return self.stock[sku]
""",
            "test_inventory.py": """\
import unittest

from inventory import Inventory


class InventoryTests(unittest.TestCase):
    def test_reserves_part_of_stock(self):
        inventory = Inventory({"A": 5})
        self.assertEqual(inventory.reserve("A", 2), 3)

    def test_can_reserve_all_stock(self):
        inventory = Inventory({"A": 2})
        self.assertEqual(inventory.reserve("A", 2), 0)

    def test_rejected_reservation_does_not_mutate(self):
        inventory = Inventory({"A": 2})
        with self.assertRaises(ValueError):
            inventory.reserve("A", 3)
        self.assertEqual(inventory.stock["A"], 2)


if __name__ == "__main__":
    unittest.main()
""",
        },
        allowed_changes=frozenset({"inventory.py"}),
        protected_files=frozenset({"test_inventory.py"}),
        test_command=("python3", "-m", "unittest", "discover", "-q"),
        hidden_command=(
            "python3",
            "-c",
            (
                "from inventory import Inventory; i=Inventory({'A': 2}); "
                "\nfor q in (0, -1):"
                "\n try: i.reserve('A', q)"
                "\n except ValueError: pass"
                "\n else: raise AssertionError('invalid quantity accepted')"
                "\nassert i.stock == {'A': 2}"
                "\nassert i.reserve('A', 1) == 1"
                "\ntry: i.reserve('missing', 1)"
                "\nexcept ValueError: pass"
                "\nelse: raise AssertionError('unknown SKU accepted')"
                "\nassert 'missing' not in i.stock"
            ),
        ),
    ),
    BenchmarkTask(
        name="python-moving-average",
        language="Python",
        difficulty="medium",
        summary="Feature implementation from a behavioral specification",
        prompt=(
            "Implement moving_average(values, window) in stats.py. Return the "
            "average for every complete sliding window, reject non-positive "
            "windows with ValueError, and return an empty list when the window "
            "is larger than the input. Modify only stats.py, do not modify "
            "tests, run `python3 -m unittest discover -q`, and stop when they pass."
        ),
        files={
            "stats.py": """\
def moving_average(values, window):
    raise NotImplementedError
""",
            "test_stats.py": """\
import unittest

from stats import moving_average


class MovingAverageTests(unittest.TestCase):
    def test_overlapping_windows(self):
        self.assertEqual(moving_average([1, 2, 3, 4], 2), [1.5, 2.5, 3.5])

    def test_full_width_window(self):
        self.assertEqual(moving_average([2, 4, 6], 3), [4.0])

    def test_oversized_window(self):
        self.assertEqual(moving_average([1, 2], 3), [])


if __name__ == "__main__":
    unittest.main()
""",
        },
        allowed_changes=frozenset({"stats.py"}),
        protected_files=frozenset({"test_stats.py"}),
        test_command=("python3", "-m", "unittest", "discover", "-q"),
        hidden_command=(
            "python3",
            "-c",
            (
                "from stats import moving_average; "
                "assert moving_average([], 1) == []; "
                "assert moving_average([3, -1, 2], 1) == [3.0, -1.0, 2.0]; "
                "\ntry: moving_average([1], 0)"
                "\nexcept ValueError: pass"
                "\nelse: raise AssertionError('window=0 accepted')"
            ),
        ),
    ),
    BenchmarkTask(
        name="javascript-retry",
        language="JavaScript",
        difficulty="medium",
        summary="Asynchronous retry and off-by-one repair",
        prompt=(
            "Fix retry(operation, retries) in retry.js. `retries` is the number "
            "of retries after the initial attempt, successful values must be "
            "returned, and the last error must be rethrown after all attempts. "
            "Modify only retry.js, leave tests unchanged, run `node --test`, "
            "and stop when they pass."
        ),
        files={
            "package.json": """\
{"type":"module","scripts":{"test":"node --test"}}
""",
            "retry.js": """\
export async function retry(operation, retries) {
  for (let attempt = 0; attempt < retries; attempt += 1) {
    try {
      return await operation();
    } catch (error) {
      if (attempt === retries) {
        throw error;
      }
    }
  }
}
""",
            "retry.test.js": """\
import assert from "node:assert/strict";
import test from "node:test";

import { retry } from "./retry.js";

test("returns a successful value", async () => {
  assert.equal(await retry(async () => 42, 2), 42);
});

test("retries before succeeding", async () => {
  let attempts = 0;
  const value = await retry(async () => {
    attempts += 1;
    if (attempts < 3) throw new Error("temporary");
    return "ok";
  }, 2);
  assert.equal(value, "ok");
  assert.equal(attempts, 3);
});

test("rethrows the final error", async () => {
  await assert.rejects(() => retry(async () => {
    throw new Error("permanent");
  }, 1), /permanent/);
});
""",
        },
        allowed_changes=frozenset({"retry.js"}),
        protected_files=frozenset({"package.json", "retry.test.js"}),
        test_command=("node", "--test"),
        hidden_command=(
            "node",
            "--input-type=module",
            "-e",
            (
                "import {retry} from './retry.js'; "
                "let n=0; "
                "if(await retry(async()=>{n++; return 'x'},0)!=='x'||n!==1)"
                " throw new Error('zero retries must attempt once');"
            ),
        ),
    ),
    BenchmarkTask(
        name="python-csv-users",
        language="Python",
        difficulty="medium",
        summary="Multi-file data-flow investigation and robust parsing",
        prompt=(
            "Fix parse_users in user_parser.py so it parses the CSV text into "
            "User objects, supports quoted commas, ignores blank rows, trims "
            "surrounding field whitespace, and rejects rows without exactly "
            "three fields using ValueError. Understand the neighboring model "
            "and formatter modules, but modify only user_parser.py. Leave tests "
            "unchanged, run `python3 -m unittest discover -q`, and stop when they pass."
        ),
        files={
            "models.py": """\
from dataclasses import dataclass


@dataclass(frozen=True)
class User:
    name: str
    email: str
    role: str
""",
            "user_parser.py": """\
from models import User


def parse_users(text):
    users = []
    for line in text.splitlines():
        name, email, role = line.split(",")
        users.append(User(name, email, role))
    return users
""",
            "formatter.py": """\
def display_name(user):
    return f"{user.name} ({user.role})"
""",
            "test_user_parser.py": """\
import unittest

from models import User
from user_parser import parse_users


class UserParserTests(unittest.TestCase):
    def test_parses_users(self):
        self.assertEqual(
            parse_users("Ada,ada@example.com,admin\\nBob,bob@example.com,user"),
            [
                User("Ada", "ada@example.com", "admin"),
                User("Bob", "bob@example.com", "user"),
            ],
        )

    def test_supports_quoted_commas_and_whitespace(self):
        self.assertEqual(
            parse_users('"Lovelace, Ada", ada@example.com , admin '),
            [User("Lovelace, Ada", "ada@example.com", "admin")],
        )

    def test_ignores_blank_rows(self):
        self.assertEqual(parse_users("\\nAda,a@example.com,user\\n\\n"), [
            User("Ada", "a@example.com", "user")
        ])


if __name__ == "__main__":
    unittest.main()
""",
        },
        allowed_changes=frozenset({"user_parser.py"}),
        protected_files=frozenset(
            {"models.py", "formatter.py", "test_user_parser.py"}
        ),
        test_command=("python3", "-m", "unittest", "discover", "-q"),
        hidden_command=(
            "python3",
            "-c",
            (
                "from user_parser import parse_users; "
                "\nfor row in ('a,b', 'a,b,c,d'):"
                "\n try: parse_users(row)"
                "\n except ValueError: pass"
                "\n else: raise AssertionError('malformed row accepted')"
            ),
        ),
    ),
    BenchmarkTask(
        name="python-bank-transfer",
        language="Python",
        difficulty="hard",
        summary="Two-file transactional state-invariant repair",
        prompt=(
            "Repair the bank transfer implementation. Account.withdraw must "
            "reject non-positive amounts and overdrafts without mutation. "
            "transfer must reject non-positive amounts and leave both accounts "
            "unchanged if either side of the transfer fails. Modify only "
            "bank/account.py and bank/service.py, leave tests unchanged, run "
            "`python3 -m unittest discover -q`, and stop when they pass."
        ),
        files={
            "bank/__init__.py": "",
            "bank/account.py": """\
class Account:
    def __init__(self, balance=0):
        self.balance = balance

    def withdraw(self, amount):
        self.balance -= amount
        if self.balance < 0:
            raise ValueError("insufficient funds")

    def deposit(self, amount):
        if amount <= 0:
            raise ValueError("amount must be positive")
        self.balance += amount
""",
            "bank/service.py": """\
def transfer(source, destination, amount):
    source.withdraw(amount)
    destination.deposit(amount)
""",
            "test_bank.py": """\
import unittest

from bank.account import Account
from bank.service import transfer


class BankTests(unittest.TestCase):
    def test_transfer_moves_money(self):
        source, destination = Account(10), Account(1)
        transfer(source, destination, 4)
        self.assertEqual((source.balance, destination.balance), (6, 5))

    def test_overdraft_does_not_mutate(self):
        source, destination = Account(3), Account(1)
        with self.assertRaises(ValueError):
            transfer(source, destination, 4)
        self.assertEqual((source.balance, destination.balance), (3, 1))

    def test_non_positive_transfer_does_not_mutate(self):
        source, destination = Account(3), Account(1)
        with self.assertRaises(ValueError):
            transfer(source, destination, 0)
        self.assertEqual((source.balance, destination.balance), (3, 1))


if __name__ == "__main__":
    unittest.main()
""",
        },
        allowed_changes=frozenset({"bank/account.py", "bank/service.py"}),
        protected_files=frozenset({"test_bank.py"}),
        test_command=("python3", "-m", "unittest", "discover", "-q"),
        hidden_command=(
            "python3",
            "-c",
            """\
from bank.account import Account
from bank.service import transfer


def expect_value_error(operation):
    try:
        operation()
    except ValueError:
        return
    raise AssertionError("expected ValueError")


source, destination = Account(5), Account(2)
for amount in (-2, 6):
    expect_value_error(lambda amount=amount: transfer(source, destination, amount))
    assert (source.balance, destination.balance) == (5, 2)


class RejectingAccount(Account):
    def deposit(self, amount):
        self.balance += amount
        raise ValueError("deposit rejected")


source, destination = Account(5), RejectingAccount(2)
expect_value_error(lambda: transfer(source, destination, 3))
assert (source.balance, destination.balance) == (5, 2)
""",
        ),
    ),
)


COMPOSITE_TASK = BenchmarkTask(
    name="composite-suite",
    language="Python + JavaScript",
    difficulty="hard",
    summary="Six independent repairs and features in one agent invocation",
    prompt=(
        "Complete all six subtasks in this repository in one run:\n"
        "1. Fix math_utils.clamp so it enforces both bounds.\n"
        "2. Fix Inventory.reserve so exact-stock reservations work and rejected "
        "quantities never mutate stock.\n"
        "3. Implement stats.moving_average according to its tests, including "
        "invalid and oversized windows.\n"
        "4. Fix retry.js so retries count attempts after the initial call and "
        "the final error is rethrown.\n"
        "5. Fix user_parser.parse_users to handle quoted commas, blank rows, "
        "and field whitespace, and raise ValueError for any nonblank row that "
        "does not contain exactly three fields.\n"
        "6. Repair Account.withdraw and transfer so invalid transfers are "
        "transactional and leave both accounts unchanged.\n\n"
        "Modify only math_utils.py, inventory.py, stats.py, retry.js, "
        "user_parser.py, bank/account.py, and bank/service.py. Do not modify "
        "tests or other files. Run `python3 -m unittest discover -q && "
        "node --test retry.test.js`, and stop when everything passes."
    ),
    files={
        path: content
        for task in ATOMIC_TASKS
        for path, content in task.files.items()
    },
    allowed_changes=frozenset().union(
        *(task.allowed_changes for task in ATOMIC_TASKS)
    ),
    protected_files=frozenset().union(
        *(task.protected_files for task in ATOMIC_TASKS)
    ),
    test_command=(
        "bash",
        "-lc",
        "python3 -m unittest discover -q && node --test retry.test.js",
    ),
    hidden_command=(
        "python3",
        "-c",
        """\
import subprocess

from bank.account import Account
from bank.service import transfer
from inventory import Inventory
from math_utils import clamp
from stats import moving_average
from user_parser import parse_users


def expect_value_error(operation):
    try:
        operation()
    except ValueError:
        return
    raise AssertionError("expected ValueError")


assert clamp(0, 0, 0) == 0
assert clamp(2.5, 1.5, 3.5) == 2.5
assert clamp(-9, -4, -1) == -4

inventory = Inventory({"A": 2})
expect_value_error(lambda: inventory.reserve("A", 0))
expect_value_error(lambda: inventory.reserve("A", -1))
assert inventory.stock == {"A": 2}
assert inventory.reserve("A", 1) == 1
expect_value_error(lambda: inventory.reserve("missing", 1))
assert "missing" not in inventory.stock

assert moving_average([], 1) == []
assert moving_average([3, -1, 2], 1) == [3.0, -1.0, 2.0]
expect_value_error(lambda: moving_average([1], 0))

for row in ("a,b", "a,b,c,d"):
    expect_value_error(lambda row=row: parse_users(row))

source, destination = Account(5), Account(2)
for amount in (-2, 6):
    expect_value_error(lambda amount=amount: transfer(source, destination, amount))
    assert (source.balance, destination.balance) == (5, 2)


class RejectingAccount(Account):
    def deposit(self, amount):
        self.balance += amount
        raise ValueError("deposit rejected")


source, destination = Account(5), RejectingAccount(2)
expect_value_error(lambda: transfer(source, destination, 3))
assert (source.balance, destination.balance) == (5, 2)

subprocess.run(
    [
        "node",
        "--input-type=module",
        "-e",
        (
            "import {retry} from './retry.js'; "
            "let n=0; "
            "if(await retry(async()=>{n++; return 'x'},0)!=='x'||n!==1) "
            "throw new Error('zero retries must attempt once');"
        ),
    ],
    check=True,
)
""",
    ),
)


TASKS = ATOMIC_TASKS + (COMPOSITE_TASK,)
TASKS_BY_NAME = {task.name: task for task in TASKS}
