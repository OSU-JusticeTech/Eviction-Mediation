# Eviction Mediation Platform

A Ruby on Rails application facilitating early-stage dispute resolution between landlords and tenants in Franklin County, Ohio.

## Overview

The Eviction Mediation Platform provides an online mediation space to reduce court filings, promote fair agreements, and support both parties in resolving rental disputes efficiently. The platform serves tenants, landlords, mediators, and administrators with role-specific features and workflows.

## Key Features

- **Two-Factor Authentication** - SMS-based verification for enhanced security
- **Bidirectional Mediation Requests** - Either party can initiate negotiations
- **Real-Time Messaging** - ActionCable-powered chat for instant communication
- **Three-Way Mediation** - Neutral mediators with separate communication channels
- **Mediation Outcome Tracking** - Structured recording of case resolutions (agreement, no agreement, or no mediation) with role-based edit permissions
- **Document Management** - PDF generation and e-signature workflows
- **Email Notifications** - Automated alerts for all major platform events
- **Resources Hub** - Educational content, FAQ, and guided resource locator
- **Admin Tools** - Mediator management, case assignment, availability tracking, and screening workflows

## Quick Start

### Prerequisites

- Make
- Docker

### Development Setup

1. Clone the repository
2. Run `make dev-setup`
3. Your app will be available on localhost:3000

If using a remote dev environment like Github Codespaces, open the Ports tab and open the Rails App port.You can also share your app by setting the port's visibility to public.

For detailed setup instructions involving non-docker software installation, see the **Developer Manual** in `docs/_posts/`.

## Documentation

Comprehensive documentation is available in the `docs/` directory:

- **[Developer Manual](docs/_posts/2025-03-04-developer-manual.markdown)** - Setup, architecture, deployment, and handoff information
- **[User Manual](docs/_posts/2025-04-02-user-manual.markdown)** - End-user guide for all roles

### For Future Development Teams

The Developer Manual includes critical handoff information:

- **Credentials Setup** - Required SMTP and Twilio account setup
- **Environment Configuration** - All required environment variables
- **Project Status** - Completed milestones, known issues, and what's left to do
- **Feature Roadmap** - Prioritized list of future enhancements
- **Testing** - Running the test suite

## Testing

Run the full test suite, including system (browser/Chrome) tests, via Docker:

```bash
make test-all
```

This spins up the database and a headless Chrome container, runs the Rails unit/integration suite plus the `test/system` browser tests, and generates a SimpleCov coverage report. All tests must pass, and coverage should remain at or above 80% (see [Contributing](#contributing)).

To run a narrower slice of tests during day-to-day development (for example, a single file), use `make test TEST=path/to/test_file.rb` instead.

## Technology Stack

- **Backend:** Ruby on Rails 8.0.1
- **Database:** Microsoft SQL Server (Azure SQL Edge)
- **Real-Time:** ActionCable (WebSockets)
- **Frontend:** ERB views, plain JavaScript
- **Email:** ActionMailer with SMTP
- **SMS:** Twilio API
- **Containerization:** Docker

## Project Status

### Completed (Fall 2024 - Autumn 2025)

- Core mediation workflows
- Two-factor authentication
- Email notification system
- Document management with e-signatures
- Resources page with educational content
- Admin and mediator tools, including mediator availability tracking
- Mediation outcome tracking and resolution recording
- Streamlined mediation request/intake forms
- Accessibility improvements (ARIA roles, keyboard navigation) across navigation and messaging views
- Comprehensive test suite
- Production deployment infrastructure

### Future Enhancements

- SMS notifications for mediation events
- Admin analytics dashboard
- Automated data deletion (1-year retention)
- Chat escalation suggestions (AI-powered)
- Mobile applications (iOS/Android)
- Multi-language support

## Contributing

This project is maintained as part of CSE 5911 at The Ohio State University. For future development teams:

1. Review the Developer Manual thoroughly
2. Set up all required credentials (SMTP, Twilio, database)
3. Run the test suite to verify your environment
4. Contact stakeholders at Franklin County Municipal Court

### Before Submitting a Pull Request

Every PR must pass the following checks locally before it's submitted for review:

1. **`make dev-setup`** - confirm the app builds and boots successfully from a clean environment.
2. **`make test-all`** - run the full test suite, including system tests that exercise the app in Chrome. A PR should not be opened with failing tests.
3. **Code coverage** - maintain at least 80% overall coverage (reported by SimpleCov after `make test-all`). Write or update tests for every new feature or bug fix so coverage doesn't regress.

## Contact

For questions about the platform or development:

- Franklin County Municipal Court: [Contact Information]
- Course Instructor: Felix Engelmann (engelmann.17@osu.edu)

---

**Note:** Detailed setup instructions, architecture documentation, and handoff information are in the Developer Manual. Start there for all development activities.
