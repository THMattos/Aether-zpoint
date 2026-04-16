# 🛠️ Engineering Tips — Building a Scalable Compiler in Python

> Practical advice for structuring the Aether Script transpiler so it stays maintainable as complexity grows.

---

## Tip 1 — Separate Your Passes: Visitor Pattern + Pipeline Architecture

The most common mistake in compiler construction is building a monolithic function that does everything at once: parses, type-checks, and emits code in one pass. This becomes unmaintainable fast.

**The right model:** Each compiler phase is an independent **AST Visitor** that traverses the tree and either transforms it or emits something from it. Phases are composed into a **pipeline**.

```python
# ast_nodes.py — Define your AST nodes as clean dataclasses
from dataclasses import dataclass, field
from typing import List, Optional
from abc import ABC, abstractmethod

@dataclass
class ASTNode(ABC):
    pass

@dataclass
class QuantumFunctionDecl(ASTNode):
    name: str
    params: List['Parameter']
    return_type: 'TypeAnnotation'
    decorators: List['Decorator']
    body: List['Statement']

@dataclass
class ZPCDecoratorNode(ASTNode):
    tolerance: float
    rollback: bool

# visitor.py — Base visitor that all passes inherit from
class ASTVisitor(ABC):
    """
    Visitor base class. Each compiler pass subclasses this.
    Subclasses only override the visit_* methods they care about.
    """

    def visit(self, node: ASTNode):
        method_name = f"visit_{type(node).__name__}"
        visitor = getattr(self, method_name, self.generic_visit)
        return visitor(node)

    def generic_visit(self, node: ASTNode):
        # Default: visit all children
        for field_name, value in vars(node).items():
            if isinstance(value, ASTNode):
                self.visit(value)
            elif isinstance(value, list):
                for item in value:
                    if isinstance(item, ASTNode):
                        self.visit(item)

# passes/type_checker.py — One pass, one responsibility
class TypeCheckerPass(ASTVisitor):
    def __init__(self):
        self.symbol_table = SymbolTable()
        self.errors: List[TypeError] = []

    def visit_QuantumFunctionDecl(self, node: QuantumFunctionDecl):
        # Only this pass knows about type checking
        self.symbol_table.enter_scope(node.name)
        for param in node.params:
            self.visit(param)
        # ... type inference logic ...
        self.symbol_table.exit_scope()

# passes/zpc_injector.py — Another pass, different responsibility
class ZPCInjectorPass(ASTVisitor):
    """
    Finds @zpc_stabilized decorators and wraps the function body
    with ZPC monitoring calls.
    """
    def visit_QuantumFunctionDecl(self, node: QuantumFunctionDecl):
        zpc = next((d for d in node.decorators if isinstance(d, ZPCDecoratorNode)), None)
        if zpc:
            node.body = self._wrap_with_zpc(node.body, zpc.tolerance, zpc.rollback)
        self.generic_visit(node)

# main.py — Clean pipeline composition
def compile_file(source_path: str, backend: str) -> CompilationResult:
    source = Path(source_path).read_text()

    # Pipeline: each stage produces input for the next
    tokens   = Lexer().tokenize(source)
    ast      = Parser().parse(tokens)

    passes = [
        TypeCheckerPass(),          # Validate types
        CoherenceCheckerPass(),     # Validate QState<T> linearity
        ZPCInjectorPass(),          # Inject ZPC monitoring
        TSEWrapperPass(),           # Wrap snapshots
        QVMapperPass(),             # Map to physical qubits
    ]

    for pass_ in passes:
        pass_.visit(ast)
        if pass_.errors:
            raise CompilationError(pass_.errors)

    # Backend selection — Strategy pattern
    backends = {
        "qiskit_sim":    QiskitBackend(),
        "openqasm":      OpenQASMBackend(),
        "ibm_quantum":   IBMQuantumBackend(),
    }
    return backends[backend].emit(ast)
```

**Why this scales:** Adding a new compiler feature (say, loop unrolling optimization) means adding one new `OptimizationPass` class. You never touch the parser, type checker, or code generator. Each class has a single, testable responsibility.

---

## Tip 2 — Immutable AST + Transformation Functions (No In-Place Mutation)

A subtle but critical design decision: **never mutate your AST in place during passes**. Instead, each transformation pass returns a *new* AST (or new nodes). This is the functional programming approach applied to compilers.

**Why it matters:**
- Debugging becomes trivial — you can inspect the AST before *and* after any pass
- Passes can be parallelized safely (no shared mutable state)
- You can implement "undo" for IDE tooling (Language Server Protocol)
- Unit testing a pass is just: `assert transform(input_ast) == expected_ast`

```python
# ❌ WRONG — mutates in place, hard to debug and test
class BadOptimizationPass(ASTVisitor):
    def visit_HadamardGate(self, node):
        if self._is_self_canceling(node):
            node.parent.children.remove(node)    # Mutating! Dangerous!

# ✅ CORRECT — returns transformed copy
from copy import deepcopy
from typing import TypeVar, Callable

T = TypeVar('T', bound=ASTNode)

def transform_ast(node: ASTNode, transformer: Callable[[ASTNode], ASTNode]) -> ASTNode:
    """
    Recursively apply transformer to all nodes.
    Returns new tree — original is untouched.
    """
    new_node = transformer(deepcopy(node))
    # Recursively transform children...
    return new_node

# passes/gate_cancellation.py
class GateCancellationPass:
    """
    Quantum circuit optimization: H·H = I, X·X = I, etc.
    Returns new optimized circuit — original unchanged.
    """
    def transform(self, circuit: QuantumCircuit) -> QuantumCircuit:
        gates = circuit.gates

        optimized = []
        i = 0
        while i < len(gates):
            if i + 1 < len(gates) and self._cancels(gates[i], gates[i+1]):
                i += 2    # Skip both — they cancel out
            else:
                optimized.append(gates[i])
                i += 1

        # Return NEW circuit with optimized gate list
        return QuantumCircuit(
            qubits=circuit.qubits,
            gates=optimized,          # New list, original unchanged
            metadata=circuit.metadata
        )

    def _cancels(self, g1: Gate, g2: Gate) -> bool:
        # H·H = I, X·X = I, CNOT·CNOT = I (same target/control)
        SELF_INVERSE = {"H", "X", "Y", "Z", "CNOT", "CZ"}
        return (
            g1.name == g2.name and
            g1.name in SELF_INVERSE and
            g1.qubits == g2.qubits
        )

# Testing is trivial because there's no side effect
def test_hadamard_cancellation():
    circuit = QuantumCircuit(qubits=[0], gates=[
        HGate(qubit=0),
        HGate(qubit=0),    # Should cancel with above
        XGate(qubit=0),
    ])
    result = GateCancellationPass().transform(circuit)
    assert len(result.gates) == 1
    assert result.gates[0] == XGate(qubit=0)
```

**Rule of thumb:** If a pass method's return type is `None`, it's probably mutating something it shouldn't be.

---

## Tip 3 — Typed Error Accumulation (Never `raise` Immediately)

Amateur compilers show you one error and stop. Professional compilers show you *all* errors at once. This matters because developers fix all errors in one iteration instead of ten.

The key: **accumulate errors rather than raising on the first one**. Use a typed `Diagnostic` system.

```python
# diagnostics.py — Structured error/warning system
from enum import Enum, auto
from dataclasses import dataclass
from typing import List

class Severity(Enum):
    ERROR   = auto()    # Compilation fails
    WARNING = auto()    # Compilation succeeds, but likely a bug
    INFO    = auto()    # Informational (e.g., optimization applied)

@dataclass(frozen=True)
class SourceLocation:
    file:   str
    line:   int
    column: int
    length: int = 1

@dataclass(frozen=True)
class Diagnostic:
    severity:    Severity
    code:        str          # e.g., "AS-E001", "AS-W042"
    message:     str
    location:    SourceLocation
    hint:        str = ""     # Suggested fix

class DiagnosticAccumulator:
    """
    Thread-safe error accumulator for compiler passes.
    Collect all errors before deciding to abort.
    """
    def __init__(self):
        self._diagnostics: List[Diagnostic] = []

    def error(self, code: str, message: str, location: SourceLocation, hint: str = ""):
        self._diagnostics.append(Diagnostic(
            severity=Severity.ERROR,
            code=code, message=message, location=location, hint=hint
        ))

    def warning(self, code: str, message: str, location: SourceLocation, hint: str = ""):
        self._diagnostics.append(Diagnostic(
            severity=Severity.WARNING,
            code=code, message=message, location=location, hint=hint
        ))

    @property
    def has_errors(self) -> bool:
        return any(d.severity == Severity.ERROR for d in self._diagnostics)

    @property
    def errors(self) -> List[Diagnostic]:
        return [d for d in self._diagnostics if d.severity == Severity.ERROR]

    def render(self) -> str:
        """Render all diagnostics as human-readable terminal output."""
        lines = []
        for d in self._diagnostics:
            icon = "❌" if d.severity == Severity.ERROR else "⚠️"
            lines.append(
                f"{icon} [{d.code}] {d.location.file}:{d.location.line}:{d.location.column}"
            )
            lines.append(f"   {d.message}")
            if d.hint:
                lines.append(f"   💡 Hint: {d.hint}")
        return "\n".join(lines)

# passes/coherence_checker.py — Uses accumulator pattern
class CoherenceCheckerPass(ASTVisitor):
    """
    Enforces QState<T> linearity: a collapsed qubit cannot be reused.
    Accumulates ALL violations before reporting.
    """
    def __init__(self, diagnostics: DiagnosticAccumulator):
        self.diag = diagnostics
        self.qubit_states: dict[str, str] = {}   # name → "Alive" | "Collapsed"

    def visit_MeasureExpr(self, node: MeasureExpr):
        name = node.register.name
        self.qubit_states[name] = "Collapsed"

    def visit_GateApplication(self, node: GateApplication):
        name = node.register.name
        if self.qubit_states.get(name) == "Collapsed":
            # Don't raise! Accumulate.
            self.diag.error(
                code     = "AS-E012",
                message  = f"Cannot apply gate to collapsed register '{name}'",
                location = node.location,
                hint     = f"Create a fresh register: `let {name}_new = allocate_qreg(...)`"
            )

# main.py — Fail at the end, not in the middle
def compile_file(source_path: str) -> CompilationResult:
    diag = DiagnosticAccumulator()

    source = Path(source_path).read_text()
    tokens = Lexer(diag).tokenize(source)
    ast    = Parser(diag).parse(tokens)

    for pass_ in [
        TypeCheckerPass(diag),
        CoherenceCheckerPass(diag),
        ZPCInjectorPass(diag),
    ]:
        pass_.visit(ast)
        # Note: we do NOT stop after each pass — collect all errors first

    if diag.has_errors:
        print(diag.render())    # Show ALL errors at once
        raise SystemExit(1)

    return QiskitBackend().emit(ast)
```

**Example output** (showing multiple errors at once — like Rust does):

```
❌ [AS-E012] examples/bigdata_quantum.as:47:5
   Cannot apply gate to collapsed register 'q_index'
   💡 Hint: Create a fresh register: `let q_index_new = allocate_qreg(...)`

❌ [AS-E003] examples/bigdata_quantum.as:52:12
   Type mismatch: expected QState<Alive>, got measured<int>
   💡 Hint: Use the unmeasured register before the measure() call

⚠️ [AS-W018] examples/bigdata_quantum.as:61:1
   ZPC tolerance 0.1 is very high — consider values below 0.01 for production

Compilation failed: 2 errors, 1 warning
```

This is the experience developers expect from modern compilers. Match it from day one.

---

## Summary

| Tip | Pattern | Benefit |
|-----|---------|---------|
| **1** | Visitor + Pipeline | Single responsibility, easy to extend |
| **2** | Immutable AST | Safe transforms, trivial unit tests |
| **3** | Diagnostic accumulator | All errors at once, better UX |

These three patterns are the difference between a prototype that works and a compiler that other developers *want* to contribute to.

---

*Aether Script — Engineered for longevity.*
