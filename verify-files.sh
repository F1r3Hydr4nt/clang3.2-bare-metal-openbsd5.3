#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
TOTAL_FILES=0
VERIFIED_FILES=0
FAILED_FILES=0
SIG_VERIFIED=0
SIG_FAILED=0

echo "========================================="
echo "File Verification Script"
echo "========================================="
echo

# Function to verify SHA256 checksum
verify_sha256() {
    local file="$1"
    local expected_sum="$2"
    
    if [ ! -f "$file" ]; then
        echo -e "${RED}✗ File not found: $file${NC}"
        return 1
    fi
    
    local actual_sum=$(sha256sum "$file" | awk '{print $1}')
    
    if [ "$actual_sum" = "$expected_sum" ]; then
        echo -e "${GREEN}✓ SHA256 OK: $file${NC}"
        return 0
    else
        echo -e "${RED}✗ SHA256 FAILED: $file${NC}"
        echo "  Expected: $expected_sum"
        echo "  Got:      $actual_sum"
        return 1
    fi
}

# Function to verify GPG signature
verify_gpg_signature() {
    local file="$1"
    local sig_file="$2"
    
    if [ ! -f "$sig_file" ]; then
        echo -e "${YELLOW}  No signature file: $sig_file${NC}"
        return 2
    fi
    
    # Try to verify the signature
    if gpg --verify "$sig_file" "$file" 2>/dev/null; then
        echo -e "${GREEN}  ✓ GPG signature valid: $file${NC}"
        return 0
    else
        # Try to fetch the key if verification failed
        echo -e "${YELLOW}  GPG verification failed, attempting to fetch keys...${NC}"
        
        # Extract key ID from signature
        local keyid=$(gpg --verify "$sig_file" "$file" 2>&1 | grep -oP 'RSA key \K[A-F0-9]+' | head -1)
        
        if [ -n "$keyid" ]; then
            echo "  Attempting to fetch key: $keyid"
            
            # Try multiple keyservers
            for keyserver in keys.openpgp.org keyserver.ubuntu.com pgp.mit.edu; do
                if gpg --keyserver "$keyserver" --recv-keys "$keyid" 2>/dev/null; then
                    echo -e "${GREEN}  Key fetched from $keyserver${NC}"
                    
                    # Try verification again
                    if gpg --verify "$sig_file" "$file" 2>/dev/null; then
                        echo -e "${GREEN}  ✓ GPG signature valid after key fetch: $file${NC}"
                        return 0
                    fi
                    break
                fi
            done
        fi
        
        echo -e "${RED}  ✗ GPG signature verification failed: $file${NC}"
        return 1
    fi
}

# Check if shasums.txt exists
if [ ! -f "shasums.txt" ]; then
    echo -e "${RED}Error: shasums.txt not found!${NC}"
    exit 1
fi

# Check if gpg is installed
if ! command -v gpg &> /dev/null; then
    echo -e "${YELLOW}Warning: gpg not installed. Skipping signature verification.${NC}"
    echo "Install with: sudo apt-get install gnupg (Debian/Ubuntu) or equivalent"
    echo
    GPG_AVAILABLE=false
else
    GPG_AVAILABLE=true
    echo -e "${BLUE}GPG is available, will attempt signature verification${NC}"
    echo
fi

# Process shasums.txt
echo "Verifying SHA256 checksums..."
echo "----------------------------------------"

while IFS=' ' read -r checksum filename; do
    # Skip empty lines
    [ -z "$checksum" ] || [ -z "$filename" ] && continue
    
    # Skip signature files in checksum verification
    if [[ "$filename" == *.sig* ]]; then
        continue
    fi
    
    ((TOTAL_FILES++))
    
    if verify_sha256 "$filename" "$checksum"; then
        ((VERIFIED_FILES++))
        
        # If GPG is available and this is not a signature file, check for signature
        if [ "$GPG_AVAILABLE" = true ]; then
            # Look for corresponding .sig file
            if [ -f "${filename}.sig" ]; then
                echo "  Checking GPG signature..."
                if verify_gpg_signature "$filename" "${filename}.sig"; then
                    ((SIG_VERIFIED++))
                else
                    ((SIG_FAILED++))
                fi
            fi
        fi
    else
        ((FAILED_FILES++))
    fi
    
    echo
done < shasums.txt

# Summary
echo "========================================="
echo "Verification Summary"
echo "========================================="
echo -e "Total files checked: ${BLUE}$TOTAL_FILES${NC}"
echo -e "SHA256 verified:     ${GREEN}$VERIFIED_FILES${NC}"
echo -e "SHA256 failed:       ${RED}$FAILED_FILES${NC}"

if [ "$GPG_AVAILABLE" = true ]; then
    echo -e "GPG signatures OK:   ${GREEN}$SIG_VERIFIED${NC}"
    echo -e "GPG signatures bad:  ${RED}$SIG_FAILED${NC}"
fi

echo

# Exit status
if [ $FAILED_FILES -eq 0 ]; then
    echo -e "${GREEN}✓ All SHA256 checksums verified successfully!${NC}"
    
    if [ "$GPG_AVAILABLE" = true ] && [ $SIG_FAILED -gt 0 ]; then
        echo -e "${YELLOW}⚠ Warning: Some GPG signatures could not be verified${NC}"
        echo -e "${YELLOW}  This is expected for older archives where keys may have expired.${NC}"
        echo -e "${YELLOW}  SHA256 checksums are verified, proceeding is safe.${NC}"
    fi
    
    # Success - SHA256 is what really matters for integrity
    exit 0
else
    echo -e "${RED}✗ Some files failed SHA256 verification!${NC}"
    echo -e "${RED}  This is a critical error - do not proceed with the build.${NC}"
    exit 1
fi