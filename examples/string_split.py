# Test string split method
text = "hello,world,python"

# Split by comma
parts = text.split(",")
print("Parts length:")
print(len(parts))

# Verify length is correct
if len(parts) == 3:
    print("Split works correctly!")
