#!/bin/bash

# Transcript Polishing Test Script
# Tests the OpenAI API transcript polishing functionality in isolation

set -euo pipefail

# Get script directory for .env file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load environment variables from .env file if it exists
if [ -f ".env" ]; then
    set -a  # Automatically export all variables
    source .env
    set +a  # Turn off automatic export
    echo -e "\033[0;34m[INFO]\033[0m Loaded configuration from .env file"
fi

# Configuration
OPENAI_API_KEY="${OPENAI_API_KEY:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Polish transcript using OpenAI API
polish_transcript() {
    local transcript="$1"
    
    if [ -z "$OPENAI_API_KEY" ]; then
        log_error "OPENAI_API_KEY not set. Please set it in .env file or as environment variable."
        return 1
    fi
    
    # Read system prompt from file
    local prompt_file="polish-prompt.txt"
    if [ ! -f "$prompt_file" ]; then
        log_error "Prompt file not found: $prompt_file"
        return 1
    fi
    
    local system_prompt
    system_prompt=$(cat "$prompt_file")
    
    log_info "Polishing transcript with OpenAI..."
    
    # Escape the transcript and prompt for JSON
    local escaped_transcript
    escaped_transcript=$(echo "$transcript" | jq -R -s .)
    local escaped_prompt
    escaped_prompt=$(echo "$system_prompt" | jq -R -s .)
    
    local response
    response=$(curl -s https://api.openai.com/v1/chat/completions \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -d "{
            \"model\": \"gpt-4o-mini\",
            \"messages\": [
                {\"role\": \"system\", \"content\": $escaped_prompt},
                {\"role\": \"user\", \"content\": $escaped_transcript}
            ]
        }")
    
    # Check if the API call was successful and extract the content
    if echo "$response" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
        local polished_content
        polished_content=$(echo "$response" | jq -r '.choices[0].message.content')
        log_success "Transcript polished successfully"
        echo "$polished_content"
    else
        log_error "Failed to polish transcript with OpenAI API"
        echo "$response" | jq -r '.error.message // "Unknown error"' >&2
        return 1
    fi
}

# Show usage information
show_usage() {
    cat << EOF
Transcript Polishing Test Script

This script tests the OpenAI API transcript polishing functionality in isolation.

USAGE:
  $0 [file_path]           # Polish transcript from file
  echo "text" | $0         # Polish transcript from stdin
  $0 --help               # Show this help

REQUIRED ENVIRONMENT VARIABLES:
  OPENAI_API_KEY - OpenAI API key for transcript polishing

EXAMPLES:
  # Polish a transcript file
  $0 transcriptions/example.txt

  # Polish text from stdin
  echo "This is um, like, a test transcript, you know?" | $0

  # Using with the converter pipeline transcript
  $0 transcriptions/my_recording.txt

EOF
}

# Check dependencies
check_dependencies() {
    local missing_deps=()
    
    # Check for required commands
    for cmd in jq curl; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        echo ""
        echo "Install missing dependencies:"
        echo "  - jq: brew install jq"
        echo "  - curl: Should be pre-installed"
        exit 1
    fi
}

# Main function
main() {
    local input_text=""
    
    # Check dependencies first
    check_dependencies
    
    # Check if input is provided via argument (file) or stdin
    if [ $# -eq 1 ]; then
        # Read from file
        local input_file="$1"
        if [ ! -f "$input_file" ]; then
            log_error "File not found: $input_file"
            exit 1
        fi
        log_info "Reading transcript from: $input_file"
        input_text=$(cat "$input_file")
    elif [ ! -t 0 ]; then
        # Read from stdin (pipe)
        log_info "Reading transcript from stdin..."
        input_text=$(cat)
    else
        log_error "No input provided. Please provide a file path or pipe text to stdin."
        show_usage
        exit 1
    fi
    
    # Check if input is empty
    if [ -z "$input_text" ]; then
        log_error "Input transcript is empty"
        exit 1
    fi
    
    echo ""
    echo "=== ORIGINAL TRANSCRIPT ==="
    echo "$input_text"
    echo ""
    echo "=== POLISHING... ==="
    echo ""
    
    # Polish the transcript
    local polished_text
    if polished_text=$(polish_transcript "$input_text"); then
        echo ""
        echo "=== POLISHED TRANSCRIPT ==="
        echo "$polished_text"
        echo ""
        log_success "Transcript polishing completed successfully!"
    else
        log_error "Failed to polish transcript"
        exit 1
    fi
}

# Handle command line arguments
if [ $# -gt 0 ]; then
    case "$1" in
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            # Treat as file path
            main "$@"
            ;;
    esac
else
    # No arguments, check for stdin
    main
fi
