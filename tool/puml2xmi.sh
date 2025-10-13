#!/bin/bash
# puml entity -> UML2 XMI
# Usage: ./puml2xmi.sh input.puml output.xmi

INPUT="$1"
OUTPUT="$2"

if [[ -z "$INPUT" || -z "$OUTPUT" ]]; then
    echo "Usage: $0 input.puml output.xmi"
    exit 1
fi

echo "Converting $INPUT -> $OUTPUT"

# Start UML2 XMI
cat <<EOL > "$OUTPUT"
<?xml version="1.0" encoding="UTF-8"?>
<XMI xmi.version="2.1" xmlns:uml="http://www.omg.org/spec/UML/20090901">
  <uml:Model xmi:type="uml:Model" name="PlantUML2Modelio">
    <packagedElement xmi:type="uml:Package" name="Entities">
EOL

in_entity=0

while IFS= read -r line; do
    # Trim leading/trailing spaces
    line=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')
    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^\' ]] && continue

    # Start of entity
    if [[ "$line" =~ ^entity[[:space:]]+([A-Za-z0-9_]+) ]]; then
        entity_name="${BASH_REMATCH[1]}"
        echo "      <packagedElement xmi:type=\"uml:Class\" name=\"$entity_name\">" >> "$OUTPUT"
        in_entity=1
        continue
    fi

    # End of entity
    if [[ "$line" == "}" ]]; then
        if [[ $in_entity -eq 1 ]]; then
            echo "      </packagedElement>" >> "$OUTPUT"
            in_entity=0
        fi
        continue
    fi

    # Skip separator lines --
    [[ "$line" == "--" ]] && continue

    # Parse attribute lines: name : type <<stereotype>>
    if [[ $in_entity -eq 1 ]]; then
        # Remove comments
        line=$(echo "$line" | sed "s/'//g")
        # Extract name and type
        if [[ "$line" =~ ^([A-Za-z0-9_]+)[[:space:]]*:[[:space:]]*([A-Za-z0-9_]+) ]]; then
            attr_name="${BASH_REMATCH[1]}"
            attr_type="${BASH_REMATCH[2]}"
            echo "        <ownedAttribute xmi:type=\"uml:Property\" name=\"$attr_name\" type=\"$attr_type\"/>" >> "$OUTPUT"
        fi
    fi
done < "$INPUT"

# Close XMI
cat <<EOL >> "$OUTPUT"
    </packagedElement>
  </uml:Model>
</XMI>
EOL

echo "Done! XMI saved to $OUTPUT"
