"""Evaluate the real GitHub expressions that guard Discord SDK decryption in CI."""

import ast
import re
import unittest
from pathlib import Path


WORKFLOW_PATH = Path(__file__).resolve().parents[1] / ".github" / "workflows" / "ci.yml"


def _extract_sdk_step_conditions(workflow: str) -> list[str]:
    lines = workflow.splitlines()
    conditions: list[str] = []

    for index, line in enumerate(lines):
        if line.strip() != "- name: Prepare pinned Discord SDK":
            continue

        for candidate in lines[index + 1 : index + 6]:
            match = re.match(r"^\s*if:\s*(.+?)\s*$", candidate)
            if match:
                conditions.append(match.group(1))
                break

    return conditions


def _evaluate_expression(expression: str, context: dict[str, str | None]) -> bool:
    replacements = {
        "github.event.pull_request.head.repo.full_name": "head_repo",
        "github.event_name": "event_name",
        "github.repository": "repository",
        "env.DISCORD_SDK_KEY_PRESENT": "key_present",
    }

    translated = expression
    for source, target in sorted(replacements.items(), key=lambda item: len(item[0]), reverse=True):
        translated = translated.replace(source, target)

    translated = translated.replace("||", " or ").replace("&&", " and ")
    tree = ast.parse(translated, mode="eval")

    def evaluate(node: ast.AST) -> object:
        if isinstance(node, ast.Expression):
            return evaluate(node.body)
        if isinstance(node, ast.Constant):
            return node.value
        if isinstance(node, ast.Name):
            if node.id not in context:
                raise AssertionError(f"Unexpected expression name: {node.id}")
            return context[node.id]
        if isinstance(node, ast.BoolOp):
            values = [bool(evaluate(value)) for value in node.values]
            if isinstance(node.op, ast.And):
                return all(values)
            if isinstance(node.op, ast.Or):
                return any(values)
        if isinstance(node, ast.Compare) and len(node.ops) == 1 and len(node.comparators) == 1:
            left = evaluate(node.left)
            right = evaluate(node.comparators[0])
            if isinstance(node.ops[0], ast.Eq):
                return left == right
            if isinstance(node.ops[0], ast.NotEq):
                return left != right
        raise AssertionError(f"Unsupported GitHub expression syntax: {ast.dump(node)}")

    return bool(evaluate(tree))


class DiscordSdkWorkflowConditionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        cls.conditions = _extract_sdk_step_conditions(cls.workflow)

    def test_both_platform_steps_have_the_guard(self) -> None:
        self.assertEqual(len(self.conditions), 2, "Expected Android and iOS SDK preparation steps")
        self.assertEqual(self.conditions[0], self.conditions[1])
        self.assertEqual(
            self.workflow.count(
                "DISCORD_SDK_KEY_PRESENT: ${{ secrets.DISCORD_MOBILE_SDK_PASSPHRASE != '' }}"
            ),
            2,
            "Both platform jobs must expose only whether the secret is present",
        )

    def test_real_conditions_allow_only_trusted_events_with_a_key(self) -> None:
        scenarios = [
            ("same-repository PR with key", "pull_request", "frpboy/Mornye", "frpboy/Mornye", "true", True),
            ("fork PR with key", "pull_request", "contributor/Mornye", "frpboy/Mornye", "true", False),
            ("same-repository PR without key", "pull_request", "frpboy/Mornye", "frpboy/Mornye", "false", False),
            ("push with key", "push", None, "frpboy/Mornye", "true", True),
            ("push without key", "push", None, "frpboy/Mornye", "false", False),
        ]

        for condition in self.conditions:
            for name, event_name, head_repo, repository, key_present, expected in scenarios:
                with self.subTest(condition=condition, scenario=name):
                    actual = _evaluate_expression(
                        condition,
                        {
                            "event_name": event_name,
                            "head_repo": head_repo,
                            "repository": repository,
                            "key_present": key_present,
                        },
                    )
                    self.assertIs(actual, expected)


if __name__ == "__main__":
    unittest.main()
