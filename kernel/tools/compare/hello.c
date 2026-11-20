/* El mismo trabajo que el programa `hello` de Fabianus: una línea y salir con 7. */
#include <unistd.h>

int main(void) {
    static const char line[] = "hola desde modo usuario\n";
    write(1, line, sizeof line - 1);
    return 7;
}
