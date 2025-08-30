# Audio Conversion and Transcription Pipeline

This script automatically processes `.m4a` audio files (default for Apple voice memos, audiobooks, music) by converting them to `.wav` or `.flac`, transcribing them with Whisper, and posting the transcriptions to Notion pages.

The script automatically changes to its own directory when run, so it works correctly when called from anywhere (perfect for terminal aliases).

## Prerequisites

### Required Dependencies
```bash
brew install ffmpeg jq
```

### Whisper.cpp Setup

Follow Whisper.cpp's installation instructions at https://github.com/ggml-org/whisper.cpp.

### Notion API Setup

1. **Create a Notion Integration**:
   - Go to [Notion Integrations](https://www.notion.so/my-integrations)
   - Click "New integration"
   - Give it a name (e.g., "Audio Transcription Bot")
   - Copy the "Internal Integration Token"

2. **Get Parent Page ID**:
   - Navigate to the Notion page where you want transcriptions to be created as children
   - Copy the page ID from the URL (the long string of characters after the last `/`)
   - Example: `https://notion.so/workspace/Page-Name-1234567890abcdef1234567890abcdef`
   - The page ID is: `1234567890abcdef1234567890abcdef`

3. **Share the Parent Page with Your Integration**:
   - Open the parent page in Notion
   - Click "Share" in the top right
   - Click "Invite" and search for your integration name
   - Select it and click "Invite"

## Usage

### Basic Usage

#### Method 1: Using .env File (Recommended)

1. **Create Configuration File**:
```bash
cp .env.example .env
vim .env
```

2. **Add Audio Files**:
   - Place your `.m4a` files in the `./source/` directory

3. **Run the Script**:
```bash
./converter.sh
```

#### Method 2: Manual Environment Variables

1. **Set Environment Variables**:
```bash
export NOTION_API_TOKEN="your_notion_api_token_here"
export NOTION_PARENT_PAGE_ID="your_parent_page_id_here"
```

2. **Add Audio Files**:
   - Place your `.m4a` files in the `./source/` directory

3. **Run the Script**:
```bash
./converter.sh
```

### Advanced Configuration

#### Using .env File

Create a `.env` file in the project directory with your configuration:

```bash
# Required Configuration
NOTION_API_TOKEN="your_notion_api_token_here"
NOTION_PARENT_PAGE_ID="your_parent_page_id_here"
WHISPER_BIN_PATH="/path/to/whisper-cli"
WHISPER_MODEL_PATH="/path/to/model.bin"

# Optional Configuration
OUTPUT_FORMAT="flac"  # or "wav" (default)
```

#### Using Environment Variables

```bash
# Use FLAC instead of WAV
export OUTPUT_FORMAT="flac"

# Run the script
./converter.sh
```

### Help
```bash
./converter.sh --help
```

### Terminal Alias Setup

For convenient use from anywhere, add an alias to your shell profile:

```bash
# Add to ~/.zshrc or ~/.bashrc
alias process-audio-files='/Users/talmage/code/utils/audio-conversion/converter.sh'

# Reload your shell configuration
source ~/.zshrc  # or source ~/.bashrc
```

Then you can run the script from any directory:
```bash
process-audio-files
```

## Output Structure

The script creates the following directory structure:

```
audio-conversion/
├── converter.sh
├── README.md
├── source/                 # Your input .m4a files (cleaned after processing)
├── converted/             # Temporary converted files (cleaned after processing)
├── transcriptions/        # Temporary transcription files (cleaned after processing)
└── archives/              # Organized archive of all processed files
    └── YYYY-MM-DD/        # Date-organized folders
        ├── filename1.m4a
        ├── filename1.wav
        ├── filename1.txt
        ├── filename2.m4a
        ├── filename2.flac
        └── filename2.txt
```

### File Processing Flow

1. **Input**: `.m4a` files placed in `./source/`
2. **Processing**: Files are converted and transcribed in temporary directories
3. **Notion Upload**: Transcriptions are posted to new Notion pages
4. **Archiving**: After successful Notion upload, all files are moved to `archives/YYYY-MM-DD/`
5. **Cleanup**: Source and temporary directories are cleaned, ready for new files

## Notion Page Structure

Each processed audio file creates a new Notion page with:
- **Title**: Name of the audio file
- **Content**: Full transcription text
- **Parent**: Your specified parent page

## Troubleshooting

### Common Issues

1. **Missing Dependencies**:
   ```bash
   brew install ffmpeg jq
   ```

2. **Whisper Not Found**:
   - Ensure Whisper.cpp is built and paths are correct
   - Check `WHISPER_BIN_PATH` and `WHISPER_MODEL_PATH` environment variables

3. **Notion API Errors**:
   - Verify your `NOTION_API_TOKEN` is correct
   - Ensure the parent page ID is valid
   - Confirm the integration has access to the parent page

4. **Permission Denied**:
   ```bash
   chmod +x converter.sh
   ```

### Debug Mode

For verbose output, you can modify the script to add debug logging:
```bash
# Add this line after the shebang to see all commands
set -x
```

## Environment Variables Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `NOTION_API_TOKEN` | ✅ | - | Your Notion integration API token |
| `NOTION_PARENT_PAGE_ID` | ✅ | - | Parent page ID for new transcription pages |
| `WHISPER_BIN_PATH` | ✅ | - | Path to Whisper CLI binary |
| `WHISPER_MODEL_PATH` | ✅ | - | Path to Whisper model file |
| `OUTPUT_FORMAT` | ❌ | `wav` | Audio output format (`wav` or `flac`) |

## Example Workflow

1. Record audio conversations and save as `.m4a` files (e.g. iphone voice memo)
2. Drop them in the `source/` directory
3. Set your Notion API credentials
4. Run `./converter.sh`
5. Check your Notion workspace for new transcription pages!

## License

This script is provided as-is for personal use.
