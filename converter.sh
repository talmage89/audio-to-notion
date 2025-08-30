#!/bin/bash

# Audio Conversion and Transcription Script
# Converts .m4a files to .wav, transcribes with Whisper, and posts to Notion

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Save current directory and change to script's directory for .env file and relative paths
ORIGINAL_DIR="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set up trap to restore original directory on script exit
trap 'cd "$ORIGINAL_DIR"' EXIT

cd "$SCRIPT_DIR"

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
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
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

# Audio conversion function with improved quality settings
audio-convert() {
    local input_file="$1"
    local output_file="$2"
    local extension="${output_file##*.}"
    local audio_filters="highpass=f=80,lowpass=f=8000,volume=1.5,dynaudnorm"
    
    extension_lower=$(echo "$extension" | tr '[:upper:]' '[:lower:]')
    
    case "$extension_lower" in
        "flac")
            # FLAC-specific settings
            ffmpeg -i "$input_file" \
                -af "$audio_filters" \
                -ar 22050 \
                -ac 1 \
                -acodec flac \
                -compression_level 8 \
                "$output_file"
            ;;
        "wav")
            # WAV-specific settings
            ffmpeg -i "$input_file" \
                -af "$audio_filters" \
                -ar 22050 \
                -ac 1 \
                -acodec pcm_s16le \
                "$output_file"
            ;;
        *)
            # Default to WAV format for unknown extensions
            log_warning "Unknown audio format '$extension', defaulting to WAV settings"
            ffmpeg -i "$input_file" \
                -af "$audio_filters" \
                -ar 22050 \
                -ac 1 \
                -acodec pcm_s16le \
                "$output_file"
            ;;
    esac
}

# Whisper transcription function
transcribe_audio() {
    local input_file="$1"
    local output_file="$2"
    
    log_info "Transcribing $input_file with optimized settings..."
    
    # Enhanced Whisper parameters to reduce repetition and improve quality:
    # -tp: Temperature (0.3) to reduce overly repetitive output
    # -bo: Consider multiple candidates to choose the best transcription
    # -bs: Beam search for better quality
    # -wt: Word threshold for better word detection
    # -et: Entropy threshold to handle uncertain segments
    # -sns: Suppress non-speech tokens to reduce noise
    "$WHISPER_BIN_PATH" \
        -m "$WHISPER_MODEL_PATH" \
        -f "$input_file" \
        -otxt \
        -of "$output_file" \
        -nt \
        -tp 0.3 \
        -bo 5 \
        -bs 5 \
        -ml 0 \
        -wt 0.01 \
        -et 2.4 \
        -sns
    
    if [ -f "${output_file}.txt" ]; then
        mv "${output_file}.txt" "$output_file"
        log_success "Transcription completed: $output_file"
        return 0
    else
        log_error "Transcription failed for $input_file"
        return 1
    fi
}

# Polish transcript using OpenAI API
polish_transcript() {
    local transcript="$1"
    
    if [ -z "$OPENAI_API_KEY" ]; then
        log_warning "OPENAI_API_KEY not set, skipping transcript polishing"
        echo "$transcript"
        return 0
    fi
    
    # Read system prompt from file
    local prompt_file="polish-prompt.txt"
    if [ ! -f "$prompt_file" ]; then
        log_warning "Prompt file not found: $prompt_file, skipping transcript polishing"
        echo "$transcript"
        return 0
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
        # Return original transcript as fallback
        echo "$transcript"
    fi
}

# Split content into chunks of specified size (default 1900 chars to be safe)
split_content_into_chunks() {
    local content="$1"
    local chunk_size="${2:-1900}"  # Default to 1900 to be under 2000 char limit
    local chunks=()
    local current_pos=0
    local content_length=${#content}
    
    while [ $current_pos -lt $content_length ]; do
        local remaining=$((content_length - current_pos))
        local chunk_end=$((current_pos + chunk_size))
        
        # If this would be the last chunk or it's smaller than chunk_size, take the rest
        if [ $remaining -le $chunk_size ]; then
            chunks+=("${content:$current_pos}")
            break
        fi
        
        # Find the last space before the chunk_size limit to avoid breaking words
        local search_start=$((chunk_end - 100))  # Look back up to 100 chars for a space
        if [ $search_start -lt $current_pos ]; then
            search_start=$current_pos
        fi
        
        local best_break=$chunk_end
        for ((i = chunk_end; i >= search_start; i--)); do
            if [ "${content:$i:1}" = " " ] || [ "${content:$i:1}" = $'\n' ]; then
                best_break=$i
                break
            fi
        done
        
        chunks+=("${content:$current_pos:$((best_break - current_pos))}")
        current_pos=$((best_break + 1))  # Skip the space/newline
    done
    
    printf '%s\0' "${chunks[@]}"
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
    
    # Split content into chunks
    local chunks=()
    while IFS= read -r -d '' chunk; do
        chunks+=("$chunk")
    done < <(split_content_into_chunks "$content")
    
    local chunk_count=${#chunks[@]}
    log_info "Content split into $chunk_count chunk(s)"
    
    # Build children array with paragraph blocks for each chunk
    local children_json="["
    for ((i = 0; i < chunk_count; i++)); do
        local escaped_chunk
        escaped_chunk=$(echo "${chunks[$i]}" | jq -R -s .)
        
        if [ $i -gt 0 ]; then
            children_json+=","
        fi
        
        children_json+="{
            \"object\": \"block\",
            \"type\": \"paragraph\",
            \"paragraph\": {
                \"rich_text\": [
                    {
                        \"type\": \"text\",
                        \"text\": {
                            \"content\": $escaped_chunk
                        }
                    }
                ]
            }
        }"
    done
    children_json+="]"
    
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
    "children": $children_json
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
    
    # Polish the transcript if OpenAI API is available
    local polished_content
    polished_content=$(polish_transcript "$transcription_content")
    
    if create_notion_page "$filename" "$polished_content"; then
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
3. Polishing transcripts using OpenAI API (if configured)
4. Creating Notion pages with the transcription content
5. Archiving all files to date-organized directories

CONFIGURATION:
The script changes to its own directory and loads environment variables 
from a .env file in that directory if present, or you can set them 
manually in your shell. This allows the script to work correctly when 
called from any directory (e.g., via an alias).

REQUIRED ENVIRONMENT VARIABLES:
  NOTION_API_TOKEN      - Your Notion integration API token
  NOTION_PARENT_PAGE_ID - The ID of the parent page for new transcription pages
  WHISPER_MODEL_PATH    - Path to Whisper model file
  WHISPER_BIN_PATH      - Path to Whisper CLI binary

OPTIONAL ENVIRONMENT VARIABLES:
  OUTPUT_FORMAT         - Audio output format: 'wav' or 'flac' (default: wav)
  OPENAI_API_KEY        - OpenAI API key for transcript polishing (optional)

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