#!/bin/bash

# Exigir pelo menos um argumento.
if [ "$#" -eq 0 ]; then
    echo "Usage: $0 <integer> [integer ...]" >&2
    exit 1
fi

# Inicializar os contadores.
even=0
odd=0

# Percorrer e validar cada argumento.
for number in "$@"; do
    if ! [[ "$number" =~ ^-?[0-9]+$ ]]; then
        echo "Error: '$number' is not an integer." >&2
        echo "Usage: $0 <integer> [integer ...]" >&2
        exit 1
    fi

    # A paridade depende apenas do ultimo algarismo.
    last_digit="${number: -1}"

    if (( last_digit % 2 == 0 )); then
        even=$((even + 1))
    else
        odd=$((odd + 1))
    fi
done

# Apresentar o resultado depois de validar todos os argumentos.
echo "Even: $even, Odd: $odd"
exit 0