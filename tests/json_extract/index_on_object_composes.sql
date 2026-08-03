-- $[0] stays on the same value, so it composes with later path steps.
SELECT JSON_EXTRACT('{"a": 1}', '$[0].a')
