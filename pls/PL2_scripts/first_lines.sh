#!/bin/bash

# Exigir exatamente um argumento.
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <directory>" >&2
    exit 1
fi

directory="$1"

# Confirmar que o argumento corresponde a uma pasta.
if [ ! -d "$directory" ]; then
    echo "Error: '$directory' is not a directory." >&2
    echo "Usage: $0 <directory>" >&2
    exit 1
fi

# Confirmar permissoes para listar e aceder ao conteudo.
if [ ! -r "$directory" ] || [ ! -x "$directory" ]; then
    echo "Error: cannot access directory '$directory'." >&2
    exit 1
fi

# Incluir ficheiros ocultos e evitar um padrao literal sem resultados.
shopt -s nullglob dotglob

found=0
status=0

for file in "$directory"/*.txt; do
    # Ignorar pastas cujo nome tambem termine em .txt.
    if [ ! -f "$file" ]; then
        continue
    fi

    found=1

    # Ler apenas a primeira linha e verificar se a leitura teve sucesso.
    if first_line=$(head -n 1 -- "$file"); then
        printf '%s: %s\n' "${file##*/}" "$first_line"
    else
        printf "Error: cannot read '%s'.\n" "$file" >&2
        status=1
    fi
done

if [ "$found" -eq 0 ]; then
    echo "No .txt files found."
fi

exit "$status"