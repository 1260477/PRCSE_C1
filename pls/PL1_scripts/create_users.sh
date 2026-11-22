checkIfUserExiste() {

    #Input da função, nnão é igual aos outros 
    local username="$1"

    if id "$username" > /dev/null 2>&1; then
        echo "O utilizador $username já existe."
        return 0
    else
        return 1
    fi
}

numberOfInput=$#
fileToUse=$1

# Verificar numero de inpuits
if [[ ! $numberOfInput -eq 1 ]]; then
    echo "Apenas é permitido 1 ficheiro!" >&2
    exit 1
fi 

# Verificar se é ficheiro e se xiste, o -f já faz isso
if [[ ! -f $fileToUse ]]; then
    echo "O input introduzido não é um ficheiro!" >&2
    exit 1
fi

# Ignorar o header
read -r header < "$fileToUse"

# Ler o resto do CSV
# while IFS=, read -r username fullname group; do
    
#     # Verificar se o grupo existe
#     if ! getent group "$group" > /dev/null; then
#         echo "O grupo $group não existe. A criar..."
#         sudo groupadd "$group"
#     fi

# done < <(tail -n +2 "$fileToUse")


# Obter todos os grupos distintos (Select Group DISTINCT)
# split pela virgula (-d ',')
# [3] com o -f3
# Depois, dop sort e -u para ser UNIQUE
groups=$(tail -n +2 "$fileToUse" | cut -d ',' -f3 | sort -u)

# Percorrer os grupos
while IFS= read -r group; do

    # isto foi GPT, não percebi como faz o getent group "$group" nem o dev/null
    if ! getent group "$group" > /dev/null; then
        echo "O grupo $group não existe. A criar..."
        sudo groupadd "$group"
    fi

done <<< "$groups"


#Agora, já preciso de toda a informação para criar os users
while IFS=, read -r username fullname group; do
    
    if ! checkIfUserExiste "$username"; then

        sudo useradd -m "$username"
        sudo usermod -c "$fullname" "$username"
        sudo usermod -g "$group" "$username"
        
        echo "User $username criado"
    fi

done < <(tail -n +2 "$fileToUse")



# [[ ]] → para avaliar expressões e condições.
# if comando → para avaliar o código de saída de comandos ou funções.



