def add(a, b):
    return a + b


def average(numbers):
    # Bug on purpose: divides by one too many
    return sum(numbers) / (len(numbers) + 1)
