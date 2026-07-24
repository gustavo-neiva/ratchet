// test.js — simple test runner for demo

const { add, subtract, multiply, divide } = require('./calculator');

let failures = 0;

function assert(condition, message) {
  if (!condition) {
    console.error(`FAIL: ${message}`);
    failures++;
  } else {
    console.log(`PASS: ${message}`);
  }
}

// Tests
assert(add(2, 3) === 5, 'add(2, 3) === 5');
assert(add(-1, 1) === 0, 'add(-1, 1) === 0');

assert(subtract(5, 3) === 2, 'subtract(5, 3) === 2');
assert(subtract(0, 5) === -5, 'subtract(0, 5) === -5');

assert(multiply(3, 4) === 12, 'multiply(3, 4) === 12');  // This will FAIL due to bug
assert(multiply(0, 10) === 0, 'multiply(0, 10) === 0');  // This will also FAIL

assert(divide(10, 2) === 5, 'divide(10, 2) === 5');
assert(divide(7, 2) === 3.5, 'divide(7, 2) === 3.5');

try {
  divide(5, 0);
  assert(false, 'divide(5, 0) should throw');
} catch (e) {
  assert(e.message === 'Division by zero', 'divide(5, 0) throws correct error');
}

console.log(`\n${failures} failure(s)`);
process.exit(failures > 0 ? 1 : 0);
