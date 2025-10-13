#!/bin/bash
# PlantUML -> MySQL DDL generator with FK and M:N join tables (fixed)

INPUT="$1"
OUTPUT="$2"

if [[ -z "$INPUT" || -z "$OUTPUT" ]]; then
    echo "Usage: $0 input.puml output.sql"
    exit 1
fi

if [[ ! -f "$INPUT" ]]; then
    echo "Error: Input file '$INPUT' does not exist!"
    exit 1
fi

echo "-- Generated SQL DDL from PlantUML for MySQL (with FK and join tables)" > "$OUTPUT"

declare -A entities_pk
declare -A entity_columns
declare -a mn_rels

# -------------------------------
# First pass: parse entities
# -------------------------------
in_entity=0
entity_name=""
primary_keys=()
first_col=1

while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')
    [[ -z "$line" || "$line" =~ ^\' ]] && continue

    if [[ "$line" =~ ^entity[[:space:]]+([A-Za-z0-9_]+) ]]; then
        entity_name="${BASH_REMATCH[1]}"
        echo "" >> "$OUTPUT"
        echo "CREATE TABLE $entity_name (" >> "$OUTPUT"
        in_entity=1
        primary_keys=()
        first_col=1
        continue
    fi

    if [[ "$line" == "}" ]]; then
        if [[ $in_entity -eq 1 ]]; then
            if [[ ${#primary_keys[@]} -gt 0 ]]; then
                echo "    ,PRIMARY KEY (${primary_keys[*]})" >> "$OUTPUT"
                entities_pk["$entity_name"]="${primary_keys[0]}"
            fi
            echo ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;" >> "$OUTPUT"
            in_entity=0
            entity_name=""
        fi
        continue
    fi

    [[ "$line" == "--" ]] && continue

    if [[ $in_entity -eq 1 ]]; then
        line=$(echo "$line" | sed "s/'//g")
        if [[ "$line" =~ ^([A-Za-z0-9_]+)[[:space:]]*:[[:space:]]*([A-Za-z0-9_]+)([[:space:]]*<<[^>]+>>)? ]]; then
            attr_name="${BASH_REMATCH[1]}"
            attr_type="${BASH_REMATCH[2]}"
            stereotype="${BASH_REMATCH[3]}"

            case "$attr_type" in
                number) sql_type="INT" ;;
                text) sql_type="VARCHAR(255)" ;;
                datetime) sql_type="DATETIME" ;;
                boolean) sql_type="TINYINT(1)" ;;
                *) sql_type="VARCHAR(255)" ;;
            esac

            [[ $first_col -eq 0 ]] && echo "," >> "$OUTPUT"
            echo -n "    $attr_name $sql_type" >> "$OUTPUT"

            if [[ "$stereotype" =~ "generated" ]]; then
                primary_keys+=("$attr_name")
                echo -n " NOT NULL AUTO_INCREMENT" >> "$OUTPUT"
            fi

            first_col=0
            entity_columns["$entity_name"]+="$attr_name "
        fi
    fi
done < "$INPUT"

# -------------------------------
# Second pass: parse relationships
# -------------------------------
while IFS= read -r rel || [[ -n "$rel" ]]; do
    rel=$(echo "$rel" | sed 's/^[ \t]*//;s/[ \t]*$//')
    [[ -z "$rel" || "$rel" =~ ^\' ]] && continue

    if [[ "$rel" =~ ^([A-Za-z0-9_]+)[[:space:]]*([|}]{1,2}o--o[{|]{1,2})[[:space:]]*([A-Za-z0-9_]+)(:.*)? ]]; then
        ent1="${BASH_REMATCH[1]}"
        connector="${BASH_REMATCH[2]}"
        ent2="${BASH_REMATCH[3]}"

        pk1="${entities_pk[$ent1]}"
        pk2="${entities_pk[$ent2]}"

        if [[ "$connector" == "}o--o{"* || "$connector" == "|o--o{"* ]]; then
            # M:N
            mn_rels+=("$ent1,$ent2")
        else
            # 1:N
            fk_name="fk_${ent1}_${ent2}"
            echo "" >> "$OUTPUT"
            echo "ALTER TABLE $ent1 ADD COLUMN ${ent2}_id INT;" >> "$OUTPUT"
            echo "ALTER TABLE $ent1 ADD CONSTRAINT $fk_name FOREIGN KEY (${ent2}_id) REFERENCES $ent2($pk2) ON DELETE CASCADE;" >> "$OUTPUT"
        fi
    fi
done < "$INPUT"

# -------------------------------
# Generate join tables for M:N
# -------------------------------
for rel in "${mn_rels[@]}"; do
    IFS=',' read -r e1 e2 <<< "$rel"
    table_name="${e1}_${e2}"
    pk1="${entities_pk[$e1]}"
    pk2="${entities_pk[$e2]}"
    echo "" >> "$OUTPUT"
    echo "CREATE TABLE $table_name (" >> "$OUTPUT"
    echo "    ${e1}_id INT NOT NULL," >> "$OUTPUT"
    echo "    ${e2}_id INT NOT NULL," >> "$OUTPUT"
    echo "    PRIMARY KEY (${e1}_id, ${e2}_id)," >> "$OUTPUT"
    echo "    CONSTRAINT fk_${table_name}_${e1} FOREIGN KEY (${e1}_id) REFERENCES $e1($pk1) ON DELETE CASCADE," >> "$OUTPUT"
    echo "    CONSTRAINT fk_${table_name}_${e2} FOREIGN KEY (${e2}_id) REFERENCES $e2($pk2) ON DELETE CASCADE" >> "$OUTPUT"
    echo ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;" >> "$OUTPUT"
done

echo "Done! Full MySQL SQL saved to $OUTPUT"
