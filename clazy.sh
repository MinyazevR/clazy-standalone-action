#!/bin/bash
set -x

options=()
extra_args=()
extra_args_before=()
files=()

for pair in $EXTRA_ARG; do
    extra_args+=( "--extra-arg=$pair" )
done

for pair in $EXTRA_ARG_BEFORE; do
    extra_args_before+=( "--extra-arg-before=$pair" )
done

if [ "$ONLY_QT" == "true" ]; then
    options+=( "--only-qt" )
fi

if [ "$QT4_COMPAT" == "true" ]; then
    options+=( "--qt4-compat" )
fi

if [ "$SUPPORTED_CHECKS_JSON" == "true" ]; then
    options+=( "--supported-checks-json" )
fi

if [ "$VISIT_IMPLICIT_CODE" == "true" ]; then
    options+=( "--visit-implicit-code" )
fi

if [ "$IGNORE_HEADERS" == "true" ] && [ -n "$DATABASE" ]; then
    cp $DATABASE/compile_commands.json $DATABASE/compile_commands_backup.json
    sed -i 's/-I\([^ ]*\)/-isystem\1/g' $DATABASE/compile_commands.json
fi

pattern='^(.*?):([0-9]+):([0-9]+): (.+): (.+) \[(.*)\]$'

if [[ -n "$ONLY_DIFF" ]]; then
    for file in $(git diff --name-only HEAD^1 HEAD); do
        file_extension="${file##*.}"
        if echo "$EXTENSIONS" | grep -q "$file_extension"; then
            files+=("$(realpath "$file")")
       fi
    done
else
    IFS=',' read -r -a extensions <<< "$EXTENSIONS"
    for ext in "${extensions[@]}"; do
        while IFS= read -r -d '' file; do
            files+=($(realpath "$file"))
        done < <(find . -name "*.$ext" -print0)
    done

fi

export CLAZY_CHECKS="$CHECKS"
EXPORT_FIXES_FILE="$PWD/clazy-fixes.yaml"

output=$(set -e; clazy-standalone --export-fixes="$EXPORT_FIXES_FILE" -p="$DATABASE" \
    --header-filter="$HEADER_FILTER" --ignore-dirs="$IGNORE_DIRS" \
    "${options[@]}" "${extra_args[@]}" "${extra_args_before[@]}" "${files[@]}" 2>&1)

warnings_file=$(mktemp)
errors_file=$(mktemp)

trap 'rm -f "$warnings_file" "$errors_file"' EXIT

echo 0 > "$warnings_file"
echo 0 > "$errors_file"

file_path=""
offset=""
message=""
code=""
level=""

if ! command -v yq &> /dev/null; then
    echo "Error: yq is not installed. Please install it first."
    exit 1
fi

declare -A warnings_seen

yq eval -o json "$EXPORT_FIXES_FILE" | jq -c '.Diagnostics[]' | while read -r diagnostic; do
    file_path=$(echo "$diagnostic" | jq -r '.DiagnosticMessage.FilePath')
    offset=$(echo "$diagnostic" | jq -r '.DiagnosticMessage.FileOffset')
    message=$(echo "$diagnostic" | jq -r '.DiagnosticMessage.Message')
    code=$(echo "$diagnostic" | jq -r '.DiagnosticName')
    level=$(echo "$diagnostic" | jq -r '.Level // "Warning"')
    
    if [[ "$file_path" != "null" && "$offset" != "null" && "$message" != "null" && "$code" != "null" ]]; then
    
        warning_key="${file_path}:${offset}:${code}"

        if [[ -n "${warnings_seen[$warning_key]}" ]]; then
            continue
        fi

        warnings_seen["$warning_key"]=1
        
        case $level in
            "Error")
                type="error"
                current_errors=$(<"$errors_file")
                ((current_errors++))
                echo "$current_errors" > "$errors_file"
                ;;
            "Warning") type="warning"
                current_warnings=$(<"$warnings_file")
                ((current_warnings++))
                echo "$current_warnings" > "$warnings_file"
                ;;
            "Note") type="notice" ;;
            *) type="warning" ;;
        esac
        
        echo "::$type file=$file_path,line=1,col=$offset::$message [$code]"
    fi
done

warnings_count=$(<"$warnings_file")
errors_count=$(<"$errors_file")

echo "::set-output name=errors-count::$errors_count"
echo "::set-output name=warnings-count::$warnings_count"

if [ "$IGNORE_HEADERS" == "true" ] && [ -n "$DATABASE" ]; then
    mv $DATABASE/compile_commands_backup.json $DATABASE/compile_commands.json
fi

rm -f "$warnings_file" "$errors_file"
