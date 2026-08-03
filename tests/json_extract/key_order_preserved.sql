-- Document order, not sorted; whitespace normalized to ", " and ": ".
SELECT JSON_EXTRACT('{"b":2,"a":1}', '$'), JSON_EXTRACT('{"a":  1 ,  "b" : 2 }', '$')
