#!/bin/bash

# Verificar se foi recebido exatamente um argumento.
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <integer>" >&2
    exit 1
fi

# Verificar se o argumento representa um numero inteiro.
if ! [[ "$1" =~ ^-?[0-9]+$ ]]; then
    echo "Error: the argument must be an integer." >&2
    echo "Usage: $0 <integer>" >&2
    exit 1
fi

# Numeros negativos nao sao primos.
if [[ "$1" == -* ]]; then
    echo "$1 is not prime"
    exit 0
fi

# Interpretar o numero em base decimal, mesmo com zeros iniciais.
number=$((10#$1))

# Zero e um nao sao primos.
if (( number < 2 )); then
    echo "$1 is not prime"
    exit 0
fi

# Procurar um divisor entre 2 e a raiz quadrada do numero.
for (( divisor = 2; divisor <= number / divisor; divisor++ )); do
    if (( number % divisor == 0 )); then
        echo "$1 is not prime"
        exit 0
    fi
done

# Se nao foi encontrado nenhum divisor, o numero e primo.
echo "$1 is prime"
exit 0