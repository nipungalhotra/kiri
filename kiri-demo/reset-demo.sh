#!/bin/zsh
# Puts the deliberate bug back into the demo project, so you can show
# "tests fail → owl is sad → Fix it → tests pass → owl celebrates" again.
cd "${0:A:h}"
cat > calculator.py <<'EOF'
def add(a, b):
    return a + b


def average(numbers):
    # Bug on purpose: divides by one too many
    return sum(numbers) / (len(numbers) + 1)
EOF
echo "Demo reset: calculator.py has its bug again."
