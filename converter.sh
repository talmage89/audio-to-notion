#!/bin/bash

# Audio Conversion and Transcription Script
# Converts .m4a files to .wav, transcribes with Whisper, and posts to Notion

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Load environment variables from .env file if it exists
if [ -f ".env" ]; then
    # Export variables from .env file, ignoring comments and empty lines
    set -a  # Automatically export all variables
    source .env
    set +a  # Turn off automatic export
    echo -e "\033[0;34m[INFO]\033[0m Loaded configuration from .env file"
fi

# Configuration - Set these environment variables
NOTION_API_TOKEN="${NOTION_API_TOKEN:-}"
NOTION_PARENT_PAGE_ID="${NOTION_PARENT_PAGE_ID:-}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-wav}"  # wav or flac
WHISPER_MODEL_PATH="${WHISPER_MODEL_PATH:-}"
WHISPER_BIN_PATH="${WHISPER_BIN_PATH:-}"

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

# Audio conversion function (from your alias)
audio-convert() {
    ffmpeg -i "$1" -ar 16000 -ac 1 "$2"
}

# Whisper transcription function
transcribe_audio() {
    local input_file="$1"
    local output_file="$2"
    
    log_info "Transcribing $input_file..."
    "$WHISPER_BIN_PATH" -m "$WHISPER_MODEL_PATH" -f "$input_file" -otxt -of "$output_file"
    
    if [ -f "${output_file}.txt" ]; then
        mv "${output_file}.txt" "$output_file"
        log_success "Transcription completed: $output_file"
        return 0
    else
        log_error "Transcription failed for $input_file"
        return 1
    fi
}

# Create Notion page
create_notion_page() {
    local title="$1"
    local content="$2"
    
    if [ -z "$NOTION_API_TOKEN" ] || [ -z "$NOTION_PARENT_PAGE_ID" ]; then
        log_error "NOTION_API_TOKEN and NOTION_PARENT_PAGE_ID must be set"
        return 1
    fi
    
    log_info "Creating Notion page: $title"
    
    # Escape content for JSON
    local escaped_content
    escaped_content=$(echo "$content" | jq -R -s .)
    
    # Create the JSON payload
    local json_payload
    json_payload=$(cat <<EOF
{
    "parent": {
        "type": "page_id",
        "page_id": "$NOTION_PARENT_PAGE_ID"
    },
    "properties": {
        "title": {
            "title": [
                {
                    "text": {
                        "content": "$title"
                    }
                }
            ]
        }
    },
    "children": [
        {
            "object": "block",
            "type": "paragraph",
            "paragraph": {
                "rich_text": [
                    {
                        "type": "text",
                        "text": {
                            "content": $escaped_content
                        }
                    }
                ]
            }
        }
    ]
}
EOF
)
    
    # Make the API call
    local response
    response=$(curl -s -X POST \
        "https://api.notion.com/v1/pages" \
        -H "Authorization: Bearer $NOTION_API_TOKEN" \
        -H "Content-Type: application/json" \
        -H "Notion-Version: 2022-06-28" \
        -d "$json_payload")
    
    # Check if successful
    if echo "$response" | jq -e '.id' > /dev/null 2>&1; then
        local page_id
        page_id=$(echo "$response" | jq -r '.id')
        log_success "Notion page created successfully: $page_id"
        return 0
    else
        log_error "Failed to create Notion page"
        echo "$response" | jq -r '.message // "Unknown error"'
        return 1
    fi
}

# Archive files after successful processing
archive_files() {
    local source_file="$1"
    local converted_file="$2"
    local transcription_file="$3"
    
    local today
    today=$(date +"%Y-%m-%d")
    local archive_dir="archives/$today"
    
    log_info "Archiving files to $archive_dir..."
    
    # Create archive directory structure
    if ! mkdir -p "$archive_dir"; then
        log_error "Failed to create archive directory: $archive_dir"
        return 1
    fi
    
    # Get filename for consistent naming
    local filename
    filename=$(basename "$source_file" .m4a)
    
    # Archive source file
    if [ -f "$source_file" ]; then
        if mv "$source_file" "$archive_dir/${filename}.m4a"; then
            log_info "Archived source file: ${filename}.m4a"
        else
            log_error "Failed to archive source file: $source_file"
            return 1
        fi
    fi
    
    # Archive converted file
    if [ -f "$converted_file" ]; then
        local converted_extension="${converted_file##*.}"
        if mv "$converted_file" "$archive_dir/${filename}.${converted_extension}"; then
            log_info "Archived converted file: ${filename}.${converted_extension}"
        else
            log_error "Failed to archive converted file: $converted_file"
            return 1
        fi
    fi
    
    # Archive transcription file
    if [ -f "$transcription_file" ]; then
        if mv "$transcription_file" "$archive_dir/${filename}.txt"; then
            log_info "Archived transcription file: ${filename}.txt"
        else
            log_error "Failed to archive transcription file: $transcription_file"
            return 1
        fi
    fi
    
    return 0
}

# Main processing function
process_audio_file() {
    local input_file="$1"
    local filename
    filename=$(basename "$input_file" .m4a)
    
    log_info "Processing: $filename.m4a"
    
    # Create output directories
    mkdir -p "converted" "transcriptions"
    
    # Convert audio
    local converted_file="converted/${filename}.${OUTPUT_FORMAT}"
    log_info "Converting to $OUTPUT_FORMAT format..."
    
    if audio-convert "$input_file" "$converted_file"; then
        log_success "Audio conversion completed: $converted_file"
    else
        log_error "Audio conversion failed for $input_file"
        return 1
    fi
    
    # Transcribe audio
    local transcription_file="transcriptions/${filename}.txt"
    if transcribe_audio "$converted_file" "$transcription_file"; then
        log_success "Transcription completed: $transcription_file"
    else
        log_error "Transcription failed for $converted_file"
        return 1
    fi
    
    # Read transcription content
    local transcription_content
    if [ -f "$transcription_file" ]; then
        transcription_content=$(cat "$transcription_file")
    else
        log_error "Transcription file not found: $transcription_file"
        return 1
    fi
    
    if create_notion_page "$filename" "$transcription_content"; then
        log_success "Notion page created successfully for $filename"
        
        # Archive all files after successful Notion upload
        if archive_files "$input_file" "$converted_file" "$transcription_file"; then
            log_success "Files archived successfully for $filename"
            log_success "Processing completed for $filename"
        else
            log_warning "Notion page created but archiving failed for $filename"
            return 1
        fi
    else
        log_warning "Audio processing completed but Notion upload failed for $filename"
        log_info "Files retained in working directories due to Notion upload failure"
        return 1
    fi
}

# Check dependencies
check_dependencies() {
    local missing_deps=()
    
    # Check for required commands
    for cmd in ffmpeg jq curl; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    # Check for whisper binary
    if [ -z "$WHISPER_BIN_PATH" ]; then
        missing_deps+=("WHISPER_BIN_PATH environment variable")
    elif [ ! -f "$WHISPER_BIN_PATH" ]; then
        missing_deps+=("whisper binary (at $WHISPER_BIN_PATH)")
    fi
    
    # Check for whisper model
    if [ -z "$WHISPER_MODEL_PATH" ]; then
        missing_deps+=("WHISPER_MODEL_PATH environment variable")
    elif [ ! -f "$WHISPER_MODEL_PATH" ]; then
        missing_deps+=("whisper model (at $WHISPER_MODEL_PATH)")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        echo ""
        echo "Install missing dependencies:"
        echo "  - ffmpeg: brew install ffmpeg"
        echo "  - jq: brew install jq"
        echo "  - curl: Should be pre-installed"
        echo "  - whisper: Build whisper.cpp and set WHISPER_BIN_PATH and WHISPER_MODEL_PATH"
        echo "  - Create a .env file with all required environment variables"
        exit 1
    fi
}

# Main script execution
main() {
    log_info "Starting audio conversion and transcription pipeline..."
    
    # Check dependencies
    check_dependencies
    
    # Check if source directory exists
    if [ ! -d "source" ]; then
        log_error "Source directory not found. Please create a 'source' directory with .m4a files."
        exit 1
    fi
    
    # Find all .m4a files in source directory
    local m4a_files
    m4a_files=()
    while IFS= read -r -d '' file; do
        m4a_files+=("$file")
    done < <(find source -name "*.m4a" -type f -print0)
    
    if [ ${#m4a_files[@]} -eq 0 ]; then
        log_warning "No .m4a files found in source directory"
        exit 0
    fi
    
    log_info "Found ${#m4a_files[@]} .m4a file(s) to process"
    
    # Process each file
    local success_count=0
    local failed_count=0
    
    for file in "${m4a_files[@]}"; do
        if process_audio_file "$file"; then
            ((success_count++))
        else
            ((failed_count++))
        fi
        echo  # Add blank line between files
    done
    
    # Clean up empty directories
    if [ -d "converted" ] && [ -z "$(ls -A converted)" ]; then
        rmdir converted
        log_info "Removed empty converted directory"
    fi
    
    if [ -d "transcriptions" ] && [ -z "$(ls -A transcriptions)" ]; then
        rmdir transcriptions
        log_info "Removed empty transcriptions directory"
    fi
    
    # Summary
    log_info "Processing complete!"
    log_success "$success_count file(s) processed successfully"
    if [ $failed_count -gt 0 ]; then
        log_warning "$failed_count file(s) failed to process"
    fi
    
    # Show archive information
    if [ $success_count -gt 0 ]; then
        local today
        today=$(date +"%Y-%m-%d")
        log_info "Successfully processed files have been archived to: archives/$today/"
        log_info "Source directory is now clean and ready for new files"
    fi
}

# Show usage information
show_usage() {
    cat << EOF
Audio Conversion and Transcription Script

This script processes .m4a files in the ./source/ directory by:
1. Converting them to .wav or .flac format
2. Transcribing them using Whisper
3. Creating Notion pages with the transcription content
4. Archiving all files to date-organized directories

CONFIGURATION:
The script loads environment variables from a .env file if present,
or you can set them manually in your shell.

REQUIRED ENVIRONMENT VARIABLES:
  NOTION_API_TOKEN      - Your Notion integration API token
  NOTION_PARENT_PAGE_ID - The ID of the parent page for new transcription pages
  WHISPER_MODEL_PATH    - Path to Whisper model file
  WHISPER_BIN_PATH      - Path to Whisper CLI binary

OPTIONAL ENVIRONMENT VARIABLES:
  OUTPUT_FORMAT         - Audio output format: 'wav' or 'flac' (default: wav)

USAGE:
  $0 [--help]

EXAMPLES:
  # Method 1: Use .env file (recommended)
  # Create .env file with your settings, then run:
  $0

  # Method 2: Set environment variables manually
  export NOTION_API_TOKEN="your_token_here"
  export NOTION_PARENT_PAGE_ID="your_parent_page_id_here"
  $0

  # Method 3: Inline environment variables
  NOTION_API_TOKEN="token" NOTION_PARENT_PAGE_ID="page_id" $0

EOF
}

# Handle command line arguments
if [ $# -gt 0 ]; then
    case "$1" in
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
fi

# Run main function
main