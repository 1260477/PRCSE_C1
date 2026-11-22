#!/bin/bash


numberOfInput=$#

authFile=$1

#O N do exercicio (default 5)
counter=${2:-5}

usage() {
    echo "Usage: $0 <log_file> [N]" >&2
}

toTable(){
    awk '{printf "%-12s %s\n", $1, $2}'
}

# Verificar numero de inpuits
if [[ $numberOfInput -lt 1 || $numberOfInput -gt 2 ]]; then
    echo "Número de argumentos inválido!" >&2
    usage
    exit 1
fi

# Verificar se é ficheiro e se xiste, o -f já faz isso
if [[ ! -f "$authFile" ]]; then
    echo "O input introduzido não é um ficheiro!" >&2
    usage
    exit 1
fi

# Verificar se N é um inteiro positivo
if [[ ! "$counter" =~ ^[1-9][0-9]*$ ]]; then
    echo "O valor de N deve ser um inteiro positivo!" >&2
    usage
    exit 1
fi

#Pensei em fazer um ciclo while a percorrer linha a linha com um regex
#MAS claramente, não pensei no grep

#a)
numberOfFailedLogin=$(grep -c "Failed password" "$authFile")
echo "a)"
echo "Existem $numberOfFailedLogin tentativas falhadas"

#e) Se não houver tentativas falhadas
if [[ "$numberOfFailedLogin" -eq 0 ]]; then
    echo "Não foram encontradas tentativas de login falhadas no ficheiro '$authFile'."
    exit 0
fi

###############################################################

#b)

extractIPs() {
    awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "from") {
                print $(i+1)
            }
        }
    }'
}


checkHowManyIP() {

    #Obtenho as linhas com Failed password
    #Em todas as linhas, o IP vem logo a seguir ao from
    # sort para depois usar o uniq
    # uniq -c
    # sort -rn (DESC)
    # depois, apenas o N primeiros

    # echo "$counter"
    grep "Failed password" "$authFile" | extractIPs | sort | uniq -c | sort -rn | head -n "$counter" | toTable

}

###############################################################

#c)
#Se percebi bem, os Users com mais tentativas falhadas, parecida com a b)
# A unica diferença, são os invalid, temos que verificar no primeiro awk

extractUserNames() {

    #Se for invalid tenho que obter o i + 3 (invalid user _ )

    awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "for") {
                if ($(i+1) == "invalid") {
                    print $(i+3)
                }else{
                    print $(i+1)
                }   
            }
        }
    }'
}

checkFailedUsers() {
    grep "Failed password" "$authFile" | extractUserNames | sort | uniq -c | sort -rn | head -n "$counter" | toTable
}


############################################################
#d)


extractRealIPs(){
    awk '{
        # Por omissão, cada linha conta como 1 tentativa
        vezes = 1

        for (i = 1; i <= NF; i++) {
            # Se encontrar "message repeated X times", guardo o X
            if ($i == "message" && $(i+1) == "repeated") {
                vezes = $(i+2)
            }

            # Quando encontrar "from", o IP está logo a seguir (i+1)
            # Imprimo o IP "vezes" vezes para o uniq -c contar todas as tentativas reais
            if ($i == "from") {
                for (k = 1; k <= vezes; k++) {
                    print $(i+1)
                }
                break
            }
        }
    }'
}

extractRealUserNames(){
    awk '{
        # Por omissão, cada linha conta como 1 tentativa
        vezes = 1

        for (i = 1; i <= NF; i++) {
            # Se encontrar "message repeated X times", guardo o X
            if ($i == "message" && $(i+1) == "repeated") {
                vezes = $(i+2)
            }

            # Quando encontrar "for", verifico se é "invalid user <nome>" ou "<nome>"
            # Imprimo o username "vezes" vezes para o uniq -c contar todas as tentativas reais
            if ($i == "for") {
                if ($(i+1) == "invalid" && $(i+2) == "user") {
                    user = $(i+3)
                } else {
                    user = $(i+1)
                }
                for (k = 1; k <= vezes; k++) {
                    print user
                }
                break
            }
        }
    }'
}

countRealFailedAttempts(){
    awk '{
        # Cada linha vale 1 por omissão; se tiver "message repeated X times", vale X
        vezes = 1
        for (i = 1; i <= NF; i++) {
            if ($i == "message" && $(i+1) == "repeated") {
                vezes = $(i+2)
                break
            }
        }
        total += vezes
    }
    END { print total }'
}

checkRealFailedTentativas(){
    # Total real de tentativas (contando "message repeated X times" como X)
    realTotal=$(grep "Failed password" "$authFile" | countRealFailedAttempts)
    echo "Total real de tentativas: $realTotal (vs $numberOfFailedLogin contando cada linha como 1)"

    # Comparação do Top N IPs (contagem real vs alínea b)
    echo "Top $counter IPs (contagem real vs 1 por linha em b):"
    grep "Failed password" "$authFile" | extractRealIPs | sort | uniq -c | sort -rn | head -n "$counter" | toTable

    # Comparação do Top N Usernames (contagem real vs alínea c)
    echo "Top $counter Usernames (contagem real vs 1 por linha em c):"
    grep "Failed password" "$authFile" | extractRealUserNames | sort | uniq -c | sort -rn | head -n "$counter" | toTable
}

###############################################################

if [[ -n "$counter" && "$counter" -gt 0 ]]; then
    echo "b)"
    checkHowManyIP
    echo "c)"
    checkFailedUsers
    echo "d)"
    checkRealFailedTentativas
fi



