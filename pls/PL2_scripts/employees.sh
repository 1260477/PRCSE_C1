#!/bin/bash

# Exigir exatamente um argumento.
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <csv_file>" >&2
    exit 1
fi

file="$1"

# Confirmar que existe um ficheiro regular com permissao de leitura.
if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "Error: '$file' must be a readable file." >&2
    echo "Usage: $0 <csv_file>" >&2
    exit 1
fi

# Usar ponto como separador decimal.
export LC_ALL=C

awk -F ',' -v script="$0" '
# Apresentar um erro e impedir resultados parciais.
function fail(message) {
    print "Error: " message > "/dev/stderr"
    print "Usage: " script " <csv_file>" > "/dev/stderr"
    failed = 1
    exit 1
}

# Remover o retorno de carro de ficheiros com linhas Windows.
{
    sub(/\r$/, "", $0)
}

# Validar o cabecalho e passar para a linha seguinte.
NR == 1 {
    if ($0 != "Name,Age,Salary") {
        fail("expected header Name,Age,Salary.")
    }
    next
}

# Validar e processar cada funcionario.
{
    if (NF != 3) {
        fail("line " NR ": expected exactly three columns.")
    }

    if ($1 !~ /[^[:space:]]/ || $1 ~ /"/) {
        fail("line " NR ": invalid name.")
    }

    if ($2 !~ /^[0-9]+$/) {
        fail("line " NR ": age must be a non-negative integer.")
    }

    if ($3 !~ /^[0-9]+([.][0-9]+)?$/) {
        fail("line " NR ": salary must be a non-negative number.")
    }

    name = $1
    age = $2 + 0
    salary = $3 + 0

    count++
    total_age += age
    total_salary += salary

    # Inicializar os extremos com o primeiro funcionario.
    if (count == 1) {
        min_salary = max_salary = salary
        min_salary_name = max_salary_name = name
        min_age = max_age = age
        youngest = oldest = name
    }

    if (salary < min_salary) {
        min_salary = salary
        min_salary_name = name
    }

    if (salary > max_salary) {
        max_salary = salary
        max_salary_name = name
    }

    if (age < min_age) {
        min_age = age
        youngest = name
    }

    if (age > max_age) {
        max_age = age
        oldest = name
    }

    # Registar cada idade distinta.
    if (!(age in age_count)) {
        ages[++age_total] = age
    }

    # Inserir o salario na posicao correta dentro da sua idade.
    position = ++age_count[age]

    while (position > 1 && salaries[age, position - 1] > salary) {
        salaries[age, position] = salaries[age, position - 1]
        position--
    }

    salaries[age, position] = salary
}

END {
    # O bloco END tambem corre quando usamos exit.
    if (failed) {
        exit 1
    }

    if (NR == 0) {
        fail("the file is empty.")
    }

    if (count == 0) {
        fail("the file has no employee records.")
    }

    printf "Lowest salary: %s - %.2f\n", min_salary_name, min_salary
    printf "Highest salary: %s - %.2f\n", max_salary_name, max_salary
    printf "Youngest employee: %s - %d\n", youngest, min_age
    printf "Oldest employee: %s - %d\n", oldest, max_age
    printf "Average salary: %.2f\n", total_salary / count
    printf "Average age: %.2f\n", total_age / count

    # Ordenar as idades por ordem crescente.
    for (i = 2; i <= age_total; i++) {
        current_age = ages[i]
        j = i - 1

        while (j >= 1 && ages[j] > current_age) {
            ages[j + 1] = ages[j]
            j--
        }

        ages[j + 1] = current_age
    }

    printf "\n%-8s %s\n", "AGE", "MEDIAN SALARY"

    # Calcular a mediana dos salarios de cada idade.
    for (i = 1; i <= age_total; i++) {
        age = ages[i]
        n = age_count[age]
        middle = int(n / 2)

        if (n % 2 == 1) {
            median = salaries[age, middle + 1]
        } else {
                        median = (salaries[age, middle] + salaries[age, middle + 1]) / 2
        }

        printf "%-8d %.2f\n", age, median
    }
}
' < "$file"

# Propagar o codigo de saida do awk.
exit $?