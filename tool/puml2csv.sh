#!/bin/bash
# PUML -> CSV generator (supports ||--o{, |o--o{, }o--o{)
# Usage: ./puml2csv_complete.sh input.puml [num_rows]

NUM_ROWS="${2:-4}"
INPUT="$1"

if [[ -z "$INPUT" ]]; then
    echo "Usage: $0 input_file [num_rows]"
    exit 1
fi
if [[ ! -f "$INPUT" ]]; then
    echo "Error: File '$INPUT' does not exist!"
    exit 1
fi

declare -A tables_cols tables_type tables_pk tables_fk table_data
declare -A mn_relations
current_table=""
in_entity=0

# -------------------------------
# Synthetic data
# -------------------------------
FIRSTNAMES=(Alice Bob Carol Dave Eve Frank Grace Heidi Ivan Judy)
LASTNAMES=(Smith Johnson Williams Brown Jones Garcia Miller Davis Wilson Taylor)
ORG_UNITS=(Physics_Department Chemistry_Department CS_Institute AI_Lab Library Admin_Office)
RESEARCH_AREAS=(AI ML Quantum_Physics Bioinformatics Neuroscience Literature History)
DOCUMENT_TITLES=("Deep_Learning_Advances" "Quantum_Entanglement_Study" "Neural_Networks_Survey" "Genome_Sequencing_Analysis")
JOURNALS=("Nature" "Science" "IEEE_Transactions" "ACM_Comp_Surveys")
EVENTS=("ICML_Conference" "NeurIPS_Conference" "Quantum_Workshop" "Bioinformatics_Summit")
GRANTS=("Horizon2025" "EU_Research_Grant" "NSF_Project_X" "AI_Innovation_Fund" "ClimateAction_Grant")
GEO_NAMES=("USA" "UK" "Germany" "France" "Japan" "Canada" "Australia" "Serbia" "Brazil" "India")

# -------------------------------
# Parse PUML
# -------------------------------
while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')
    [[ -z "$line" || "$line" =~ ^\' ]] && continue

    # entity start
    if [[ "$line" =~ ^entity[[:space:]]+([A-Za-z0-9_]+) ]]; then
        current_table="${BASH_REMATCH[1]}"
        in_entity=1
        tables_cols["$current_table"]=""
        tables_type["$current_table"]=""
        tables_pk["$current_table"]=""
        tables_fk["$current_table"]=""
        continue
    fi
    [[ "$line" == "}" ]] && in_entity=0
    [[ "$line" == "--" ]] && continue

    # columns
    if [[ $in_entity -eq 1 ]]; then
        if [[ "$line" =~ ^([A-Za-z0-9_]+)[[:space:]]*:[[:space:]]*([A-Za-z0-9_]+)([[:space:]]*<<[^>]+>>)? ]]; then
            col="${BASH_REMATCH[1]}"
            typ="${BASH_REMATCH[2]}"
            st="${BASH_REMATCH[3]}"
            tables_cols["$current_table"]+="$col,"
            tables_type["$current_table"]+="$typ,"
            if [[ "$st" =~ "generated" ]]; then
                tables_pk["$current_table"]="$col"
            fi
        fi
    fi

    # M:N relation }o--o{
    if [[ "$line" =~ ^([A-Za-z0-9_]+)[[:space:]]*\}[o|]\-\-o\{[[:space:]]*([A-Za-z0-9_]+) ]]; then
        ent1="${BASH_REMATCH[1]}"
        ent2="${BASH_REMATCH[2]}"
        rel_name="${ent1}_${ent2}"
        mn_relations["$rel_name"]="$ent1:$ent2"
    fi

    # 1:N relation ||--o{
    if [[ "$line" =~ ^([A-Za-z0-9_]+)[[:space:]]*\|\|--o\{[[:space:]]*([A-Za-z0-9_]+) ]]; then
        parent="${BASH_REMATCH[1]}"
        child="${BASH_REMATCH[2]}"
        fk_col="${parent}_id"
        tables_fk["$child"]+="$fk_col:$parent:${tables_pk[$parent]},"
    fi

    # 1:N relation |o--o{ (additional)
    if [[ "$line" =~ ^([A-Za-z0-9_]+)[[:space:]]*\|o--o\{[[:space:]]*([A-Za-z0-9_]+) ]]; then
        child="${BASH_REMATCH[1]}"
        parent="${BASH_REMATCH[2]}"
        fk_col="${parent}_id"
        tables_fk["$child"]+="$fk_col:$parent:${tables_pk[$parent]},"
    fi

done < "$INPUT"

# -------------------------------
# Topo sort for FK dependencies
# -------------------------------
declare -A visited
ordered_tables=()
topo_sort() {
    local table="$1"
    [[ "${visited[$table]}" == "1" ]] && return
    visited["$table"]=1
    if [[ -n "${tables_fk[$table]}" ]]; then
        IFS=',' read -ra fks <<< "${tables_fk[$table]}"
        for fk_def in "${fks[@]}"; do
            [[ -z "$fk_def" ]] && continue
            IFS=':' read -r fk_col ref_table ref_col <<< "$fk_def"
            topo_sort "$ref_table"
        done
    fi
    ordered_tables+=("$table")
}
for t in "${!tables_cols[@]}"; do
    topo_sort "$t"
done

# -------------------------------
# Generate entity CSVs
# -------------------------------
for table in "${ordered_tables[@]}"; do
    csv_file="${table}.csv"
    echo "Generating $csv_file"
    cols=$(echo "${tables_cols[$table]}" | sed 's/,$//')
    IFS=',' read -ra col_arr <<< "$cols"
    types=$(echo "${tables_type[$table]}" | sed 's/,$//')
    IFS=',' read -ra type_arr <<< "$types"

    (IFS=','; echo "${col_arr[*]}") > "$csv_file"
    table_data["$table"]=""

    for ((i=0;i<NUM_ROWS;i++)); do
        row=""
        for idx in "${!col_arr[@]}"; do
            col="${col_arr[$idx]}"
            typ="${type_arr[$idx]}"
            val=""

            fk_assigned=0
            if [[ -n "${tables_fk[$table]}" ]]; then
                IFS=',' read -ra fks <<< "${tables_fk[$table]}"
                for fk_def in "${fks[@]}"; do
                    [[ -z "$fk_def" ]] && continue
                    IFS=':' read -r fk_col ref_table ref_col <<< "$fk_def"
                    if [[ "$col" == "$fk_col" ]]; then
                        vals=(${table_data[$ref_table]})
                        val="${vals[$((RANDOM % ${#vals[@]}))]}"
                        fk_assigned=1
                        break
                    fi
                done
            fi

            if [[ $fk_assigned -eq 0 ]]; then
                case "$col" in
                    firstname) val="${FIRSTNAMES[$((RANDOM % ${#FIRSTNAMES[@]}))]}" ;;
                    lastname) val="${LASTNAMES[$((RANDOM % ${#LASTNAMES[@]}))]}" ;;
                    name)
                        if [[ "$table" == "OrganisationUnit" ]]; then
                            val="${ORG_UNITS[$((RANDOM % ${#ORG_UNITS[@]}))]}"
                        elif [[ "$table" == "ResearchArea" ]]; then
                            val="${RESEARCH_AREAS[$((RANDOM % ${#RESEARCH_AREAS[@]}))]}"
                        elif [[ "$table" == "Geolocation" ]]; then
                            val="${GEO_NAMES[$((RANDOM % ${#GEO_NAMES[@]}))]}"
                        else
                            val="Name$((RANDOM%100))"
                        fi ;;
                    title)
                        if [[ "$table" == "Document" ]]; then
                            val="${DOCUMENT_TITLES[$((RANDOM % ${#DOCUMENT_TITLES[@]}))]}"
                        elif [[ "$table" == "Journal" ]]; then
                            val="${JOURNALS[$((RANDOM % ${#JOURNALS[@]}))]}"
                        elif [[ "$table" == "Event" ]]; then
                            val="${EVENTS[$((RANDOM % ${#EVENTS[@]}))]}"
                        else
                            val="Title$((RANDOM%100))"
                        fi ;;
                    identifier) val="${GRANTS[$((RANDOM % ${#GRANTS[@]}))]}" ;;
                    *) 
                        if [[ "$typ" =~ number|INT ]]; then
                            if [[ "${tables_pk[$table]}" == "$col" ]]; then
                                val=$((i+1))
                            else
                                val=$((RANDOM%100))
                            fi
                        elif [[ "$typ" =~ text|VARCHAR ]]; then
                            val="Val$((RANDOM%100))"
                        elif [[ "$typ" =~ datetime|DATETIME ]]; then
                            val="2025-10-$((RANDOM%28+1)) 12:00:00"
                        elif [[ "$typ" =~ boolean|TINYINT ]]; then
                            val=$((RANDOM%2))
                        else
                            val="Val$((RANDOM%100))"
                        fi ;;
                esac
            fi

            [[ -z "$row" ]] && row="$val" || row="$row,$val"
        done
        echo "$row" >> "$csv_file"

        # save PK
        pk_col="${tables_pk[$table]}"
        for idx in "${!col_arr[@]}"; do
            if [[ "${col_arr[$idx]}" == "$pk_col" ]]; then
                IFS=',' read -ra row_vals <<< "$row"
                table_data["$table"]+="${row_vals[$idx]} "
                break
            fi
        done
    done
done

# -------------------------------
# Generate M:N join tables
# -------------------------------
for rel_name in "${!mn_relations[@]}"; do
    IFS=':' read -r ent1 ent2 <<< "${mn_relations[$rel_name]}"
    join_csv="${rel_name}.csv"
    echo "Generating join table $join_csv"
    echo "${ent1}_id,${ent2}_id" > "$join_csv"
    vals1=(${table_data[$ent1]})
    vals2=(${table_data[$ent2]})
    for ((i=0;i<NUM_ROWS;i++)); do
        id1="${vals1[$((RANDOM % ${#vals1[@]}))]}"
        id2="${vals2[$((RANDOM % ${#vals2[@]}))]}"
        echo "$id1,$id2" >> "$join_csv"
    done
done

echo "Done! CSV files generated for all entities and join tables."
