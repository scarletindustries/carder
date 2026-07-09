// Source of the committed `compute.wasm` fixture — the Java program run end-to-end on the BEAM
// through 2core (decode → validate → lower → emit → BEAM → instantiate → invoke), with the TeaVM
// WASM GC host runtime provided by `src/twocore/runtime/rt_teavm.gleam`.
//
// It exercises the WASM GC surface that matters: object allocation (`struct.new`), an array-free
// set of objects behind an interface, and VIRTUAL DISPATCH (`call_ref` through GC-typed vtables) —
// the mechanism TeaVM uses instead of `call_indirect`. `compute()` returns 9 + 12 + 25 = 46.
//
// Rebuild (TeaVM 0.15.0, JDK 17+ to run the compiler; the archetype's WASM GC Maven plugin with
// <targetType>WEBASSEMBLY_GC</targetType> and <mainClass>demo.Client</mainClass>):
//   mvn -q -B package        # → target/generated/wasm/teavm/classes.wasm  (this fixture)
package demo;

import org.teavm.interop.Export;

public class Client {

    interface Shape {
        int area();
    }

    static final class Square implements Shape {
        final int s;
        Square(int s) { this.s = s; }
        public int area() { return s * s; }
    }

    static final class Circle implements Shape {
        final int r;
        Circle(int r) { this.r = r; }
        public int area() { return 3 * r * r; }
    }

    @Export(name = "compute")
    public static int compute() {
        Shape a = new Square(3);
        Shape b = new Circle(2);
        Shape c = new Square(5);
        return a.area() + b.area() + c.area(); // 9 + 12 + 25 = 46
    }

    public static void main(String[] args) {
        compute();
    }
}
