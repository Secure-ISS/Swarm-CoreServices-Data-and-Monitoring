#!/bin/bash
# Automated release creation with semantic versioning and changelog generation

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_BRANCH="main"

# ============================================================================
# Functions
# ============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_header() {
    echo -e "${BLUE}$1${NC}"
}

get_current_version() {
    # Get latest tag
    git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0"
}

parse_version() {
    local version=$1
    # Remove 'v' prefix
    version=${version#v}

    # Parse major.minor.patch
    IFS='.' read -r MAJOR MINOR PATCH <<< "$version"

    echo "$MAJOR $MINOR $PATCH"
}

determine_next_version() {
    local current_version=$1
    local bump_type=$2

    read -r MAJOR MINOR PATCH <<< "$(parse_version "$current_version")"

    case "$bump_type" in
        major)
            MAJOR=$((MAJOR + 1))
            MINOR=0
            PATCH=0
            ;;
        minor)
            MINOR=$((MINOR + 1))
            PATCH=0
            ;;
        patch)
            PATCH=$((PATCH + 1))
            ;;
        *)
            log_error "Invalid bump type: $bump_type"
            exit 1
            ;;
    esac

    echo "v${MAJOR}.${MINOR}.${PATCH}"
}

detect_version_bump() {
    local since_tag=$1

    # Check commit messages since last tag
    local commits=$(git log "$since_tag..HEAD" --pretty=%B)

    # Breaking changes -> major
    if echo "$commits" | grep -qi "BREAKING CHANGE"; then
        echo "major"
        return
    fi

    # New features -> minor
    if echo "$commits" | grep -qiE "^feat(\(.*\))?:"; then
        echo "minor"
        return
    fi

    # Bug fixes and other -> patch
    echo "patch"
}

generate_changelog() {
    local since_tag=$1
    local new_version=$2
    local changelog_file="CHANGELOG_${new_version}.md"

    log_info "Generating changelog..."

    cat > "$changelog_file" <<EOF
# Changelog - $new_version

**Release Date:** $(date -u +"%Y-%m-%d")

EOF

    # Get commits
    local commits=$(git log "$since_tag..HEAD" --pretty=format:"%s|||%H|||%an")

    # Categorize commits
    local features=()
    local fixes=()
    local docs=()
    local refactors=()
    local tests=()
    local chores=()
    local breaking=()

    while IFS='|||' read -r subject hash author; do
        # Check for breaking changes
        local commit_body=$(git log -1 "$hash" --pretty=%b)
        if echo "$commit_body" | grep -qi "BREAKING CHANGE"; then
            breaking+=("- $subject ($hash)")
        fi

        # Categorize by type
        if [[ $subject =~ ^feat(\(.*\))?: ]]; then
            features+=("- ${subject#feat*: } ($hash)")
        elif [[ $subject =~ ^fix(\(.*\))?: ]]; then
            fixes+=("- ${subject#fix*: } ($hash)")
        elif [[ $subject =~ ^docs(\(.*\))?: ]]; then
            docs+=("- ${subject#docs*: } ($hash)")
        elif [[ $subject =~ ^refactor(\(.*\))?: ]]; then
            refactors+=("- ${subject#refactor*: } ($hash)")
        elif [[ $subject =~ ^test(\(.*\))?: ]]; then
            tests+=("- ${subject#test*: } ($hash)")
        elif [[ $subject =~ ^chore(\(.*\))?: ]]; then
            chores+=("- ${subject#chore*: } ($hash)")
        else
            chores+=("- $subject ($hash)")
        fi
    done <<< "$commits"

    # Write breaking changes
    if [ ${#breaking[@]} -gt 0 ]; then
        cat >> "$changelog_file" <<EOF
## ⚠️ Breaking Changes

${breaking[*]}

EOF
    fi

    # Write features
    if [ ${#features[@]} -gt 0 ]; then
        cat >> "$changelog_file" <<EOF
## ✨ Features

EOF
        printf '%s\n' "${features[@]}" >> "$changelog_file"
        echo "" >> "$changelog_file"
    fi

    # Write bug fixes
    if [ ${#fixes[@]} -gt 0 ]; then
        cat >> "$changelog_file" <<EOF
## 🐛 Bug Fixes

EOF
        printf '%s\n' "${fixes[@]}" >> "$changelog_file"
        echo "" >> "$changelog_file"
    fi

    # Write refactoring
    if [ ${#refactors[@]} -gt 0 ]; then
        cat >> "$changelog_file" <<EOF
## 🔨 Refactoring

EOF
        printf '%s\n' "${refactors[@]}" >> "$changelog_file"
        echo "" >> "$changelog_file"
    fi

    # Write documentation
    if [ ${#docs[@]} -gt 0 ]; then
        cat >> "$changelog_file" <<EOF
## 📚 Documentation

EOF
        printf '%s\n' "${docs[@]}" >> "$changelog_file"
        echo "" >> "$changelog_file"
    fi

    # Write tests
    if [ ${#tests[@]} -gt 0 ]; then
        cat >> "$changelog_file" <<EOF
## 🧪 Tests

EOF
        printf '%s\n' "${tests[@]}" >> "$changelog_file"
        echo "" >> "$changelog_file"
    fi

    # Write chores
    if [ ${#chores[@]} -gt 0 ]; then
        cat >> "$changelog_file" <<EOF
## 🔧 Chores

EOF
        printf '%s\n' "${chores[@]}" >> "$changelog_file"
        echo "" >> "$changelog_file"
    fi

    # Add contributors
    local contributors=$(git log "$since_tag..HEAD" --pretty=format:"%an" | sort -u)
    cat >> "$changelog_file" <<EOF
## 👥 Contributors

$(echo "$contributors" | sed 's/^/- /')

EOF

    echo "$changelog_file"
}

update_main_changelog() {
    local version_changelog=$1
    local new_version=$2

    if [ ! -f "CHANGELOG.md" ]; then
        log_warn "CHANGELOG.md not found, creating new one"
        echo "# Changelog" > CHANGELOG.md
        echo "" >> CHANGELOG.md
    fi

    # Prepend new version to main changelog
    local temp_file=$(mktemp)
    cat "CHANGELOG.md" > "$temp_file"

    {
        echo "# Changelog"
        echo ""
        cat "$version_changelog" | tail -n +3  # Skip header
        echo ""
        echo "---"
        echo ""
        tail -n +3 "$temp_file"  # Skip old header
    } > "CHANGELOG.md"

    rm "$temp_file"
    log_info "Updated CHANGELOG.md"
}

create_git_tag() {
    local version=$1
    local changelog_file=$2

    log_info "Creating git tag: $version"

    # Create annotated tag with changelog as message
    git tag -a "$version" -F "$changelog_file"

    log_info "Tag created: $version"
}

push_to_remote() {
    local version=$1
    local remote=${2:-origin}

    log_info "Pushing to remote: $remote"

    # Push commits and tags
    git push "$remote" "$DEFAULT_BRANCH"
    git push "$remote" "$version"

    log_info "Pushed to $remote"
}

create_github_release() {
    local version=$1
    local changelog_file=$2

    if ! command -v gh &> /dev/null; then
        log_warn "GitHub CLI (gh) not found, skipping GitHub release"
        return
    fi

    log_info "Creating GitHub release..."

    gh release create "$version" \
        --title "Release $version" \
        --notes-file "$changelog_file" \
        --target "$DEFAULT_BRANCH"

    log_info "GitHub release created: $version"
}

# ============================================================================
# Main
# ============================================================================

main() {
    cd "$PROJECT_ROOT"

    log_header "═══════════════════════════════════════════════════════"
    log_header "          AUTOMATED RELEASE CREATION"
    log_header "═══════════════════════════════════════════════════════"
    echo ""

    # Parse arguments
    BUMP_TYPE=""
    DRY_RUN=false
    SKIP_GITHUB=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --major|--minor|--patch)
                BUMP_TYPE="${1#--}"
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --skip-github)
                SKIP_GITHUB=true
                shift
                ;;
            --help)
                cat <<EOF
Usage: $0 [OPTIONS]

Options:
    --major         Bump major version (breaking changes)
    --minor         Bump minor version (new features)
    --patch         Bump patch version (bug fixes)
    --dry-run       Show what would be done without making changes
    --skip-github   Skip GitHub release creation
    --help          Show this help message

If no version bump is specified, it will be detected automatically from commits.

EOF
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Check git status
    if [ -n "$(git status --porcelain)" ]; then
        log_error "Working directory is not clean. Commit or stash changes first."
        exit 1
    fi

    # Get current version
    CURRENT_VERSION=$(get_current_version)
    log_info "Current version: $CURRENT_VERSION"

    # Determine bump type
    if [ -z "$BUMP_TYPE" ]; then
        log_info "Auto-detecting version bump from commits..."
        BUMP_TYPE=$(detect_version_bump "$CURRENT_VERSION")
        log_info "Detected bump type: $BUMP_TYPE"
    fi

    # Calculate new version
    NEW_VERSION=$(determine_next_version "$CURRENT_VERSION" "$BUMP_TYPE")
    log_info "New version: $NEW_VERSION"

    # Generate changelog
    CHANGELOG_FILE=$(generate_changelog "$CURRENT_VERSION" "$NEW_VERSION")
    log_info "Changelog generated: $CHANGELOG_FILE"

    # Show changelog
    echo ""
    log_header "Generated Changelog:"
    echo ""
    cat "$CHANGELOG_FILE"
    echo ""

    # Confirm
    if [ "$DRY_RUN" = true ]; then
        log_warn "DRY RUN MODE - No changes will be made"
        exit 0
    fi

    read -p "Create release $NEW_VERSION? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warn "Release cancelled"
        exit 0
    fi

    # Update main changelog
    update_main_changelog "$CHANGELOG_FILE" "$NEW_VERSION"

    # Commit changelog updates
    git add CHANGELOG.md
    git commit -m "chore: Update changelog for $NEW_VERSION"

    # Create tag
    create_git_tag "$NEW_VERSION" "$CHANGELOG_FILE"

    # Push to remote
    push_to_remote "$NEW_VERSION"

    # Create GitHub release
    if [ "$SKIP_GITHUB" = false ]; then
        create_github_release "$NEW_VERSION" "$CHANGELOG_FILE"
    fi

    echo ""
    log_header "═══════════════════════════════════════════════════════"
    log_info "✓ Release $NEW_VERSION created successfully!"
    log_header "═══════════════════════════════════════════════════════"
    echo ""
}

main "$@"
