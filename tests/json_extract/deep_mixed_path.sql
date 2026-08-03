SELECT JSON_EXTRACT('{"nested": {"deep": {"x": [1, {"y": "z"}]}}}', '$.nested.deep.x[1]')
