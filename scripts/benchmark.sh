#!/bin/bash
# Benchmark: 100 invocaciones a la Lambda zig-demo

FUNCTION_URL=$(aws lambda get-function-url-config \
  --function-name zig-demo \
  --region us-east-1 \
  --query 'FunctionUrl' \
  --output text)

if [ -z "$FUNCTION_URL" ]; then
  echo "Error: no se pudo obtener la Function URL"
  exit 1
fi

echo "URL: $FUNCTION_URL"
echo "Ejecutando 100 invocaciones..."
echo ""

total=0
count=100

for i in $(seq 1 $count); do
  time_ms=$(curl -s -o /dev/null -w "%{time_total}" "$FUNCTION_URL")
  time_ms=$(echo "$time_ms * 1000" | bc)
  printf "  #%03d: %.1fms\n" "$i" "$time_ms"
  total=$(echo "$total + $time_ms" | bc)
done

avg=$(echo "scale=1; $total / $count" | bc)
echo ""
echo "Total: ${total}ms"
echo "Promedio: ${avg}ms"
echo "Invocaciones: $count"
