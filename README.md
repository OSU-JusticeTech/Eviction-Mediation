# Eviction Mediation Platform

A Ruby on Rails application facilitating early-stage dispute resolution between landlords and tenants in Franklin County, Ohio.

## Overview

The Eviction Mediation Platform provides an online mediation space to reduce court filings, promote fair agreements, and support both parties in resolving rental disputes efficiently. The platform serves tenants, landlords, mediators, and administrators with role-specific features and workflows.

## Technology Stack

These technologies and libraries (except for Docker) are managed by Rails (Gems) and do not need to be installed independently.

- **Backend:** Ruby on Rails 8.0.1
- **Database:** Microsoft SQL Server (Azure SQL Edge)
- **Real-Time:** ActionCable (WebSockets)
- **Frontend:** ERB views, plain JavaScript
- **Email:** ActionMailer with SMTP
- **SMS:** Twilio API
- **Containerization:** Docker

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

## Development

### Dependencies

This application makes use of <a href="https://docs.docker.com/engine/install/" target="_blank" >Docker</a> for dev and production purposes and to track infrastructure dependencies (IaC). <a href="https://en.wikipedia.org/wiki/Make_(software)" target="_blank" >Make</a> and Docker are the only software packages needed to develop this app, as Docker and Rails will fetch and install software libraries and dependencies the app needs. Rails includes a web server (Puma) which can be used as is, however, a reverse proxy is recommended for staging and production deployments.

### Development Setup

**ENVIRONMENT VARIABLES**

Certain environment variables are declared in the Makefile and served to Docker Compose files. These can be overriden by creating a file called `env.mk` in your root directory (i.e. `export RAILS_ENV=production`). Makefile commands (targets) can also be overriden by creating a file called `env-targets.mk`.

**DO NOT EDIT THE MAKEFILE DIRECTLY, USE OVERRIDES INSTEAD. MAKEFILE EDITS MAY BE ADDED, BUT REQUIRE APPROVAL FROM THE PRIMARY MAINTAINER**

### Quick Start

1. Ensure your dev environment has Make and Docker installed
2. Clone the repository
3. Run `make dev-setup`
4. Your app will be available on localhost:3000

If using a remote dev environment like Github Codespaces, open the Ports tab and open the Rails App port.You can also share your app by setting the port's visibility to public.

For detailed setup instructions involving non-docker software installation, see the **Developer Manual** in `docs/_posts/`.

### Manual Setup (Docker-less)

Comprehensive documentation is available in the `docs/` directory:

- **[Developer Manual](docs/_posts/2025-03-04-developer-manual.markdown)** - Setup, architecture, deployment, and handoff information
- **[User Manual](docs/_posts/2025-04-02-user-manual.markdown)** - End-user guide for all roles

### Testing

Run the full test suite (unit, integration, and system tests) via Docker:

`make test`

By default this runs headless. To run with a headed Chrome instance (viewable at `http://localhost:7900/?autoconnect=1&resize=scale`):

`make test TEST_ALL=true`

Run a specific test file or directory:


- `make test TEST=test/controllers/messages_controller_test.rb`
- `make test TEST=test/system`

Both flags can be combined — e.g. `make test TEST=test/system TEST_ALL=true` to watch system tests live in the browser.

Coverage is generated via SimpleCov and should remain at or above 80%.

## Deployment

To deploy, run `make up`. This pulls the published web image from the public Docker Hub repository and starts the app container, eliminating the need to build the image on the server and the ability to deploy this app through serverless container services.

The image and tag are controlled by the `WEB_IMAGE` and `WEB_TAG` variables, which resolve to `WEB_IMAGE_REF`. Override them in `env.mk` to deploy a different image or tag.

A GitHub Action already builds and pushes the image on merge to `main`, so most deployments require no manual publishing. To push a one-off image (for example, testing a change on a specific tag before merging), set `DOCKER_USERNAME` and `DOCKER_TOKEN` in `env.mk` and run `make publish`.

## Contributing

This project is maintained by Justice Tech at The Ohio State University. For future development teams:

1. Review this README and Project documentation thoroughly
2. Set up all required credentials (SMTP, Twilio, database)
3. Run `make dev-setup` and the test suite to verify your environment
4. Contact stakeholders at Franklin County Municipal Court

### Before Submitting a Pull Request

Every PR must pass the following checks locally before it's submitted for review:

1. **`make dev-setup`** - confirm the app builds and boots successfully from a clean environment.
2. **`make test`** - run the full test suite, including system tests that exercise the app in Chrome. A PR should not be opened with failing tests.
3. **Code coverage** - maintain at least **80% overall coverage** (reported by SimpleCov after `make test`). Write or update tests for every new feature or bug fix so coverage doesn't regress.


## Contact

For questions about the platform or development, contact a member of the Justice Tech team:

- Justice Tech: https://moritzlaw.osu.edu/faculty-research/justicetech-program
- LinkedIn Page: linkedin.com/company/105874275/


### Additional Contributors

Novel Minds LLC - Development Contractor
- https://novelminds.io/
- 608.284.8513
- info@novelminds.io

---

