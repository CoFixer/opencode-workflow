# Backend Development Guides

This directory contains guides for NestJS backend development.

## Available Guides

| Guide | Purpose |
|-------|---------|
| AUTHENTICATION-GUIDE.md | JWT auth, guards, decorators |
| BASE-CONTROLLER-GUIDE.md | Base controller patterns |
| BEST-PRACTICES.md | General NestJS best practices |
| DATABASE-PATTERNS-GUIDE.md | TypeORM patterns and migrations |
| ERROR-HANDLING-GUIDE.md | Exception filters and error responses |
| RBAC-GUIDE.md | Role-based access control |
| ROUTING-AND-CONTROLLERS-GUIDE.md | Controller organization |
| SERVICES-AND-REPOSITORIES-GUIDE.md | Service layer patterns |
| TESTING-GUIDE.md | Unit and integration testing |
| VALIDATION-GUIDE.md | DTO validation with class-validator |

## Quick Reference

### Creating a New Module

```bash
# Generate module, controller, service
nest g module features/my-feature
nest g controller features/my-feature
nest g service features/my-feature

# Create DTOs
mkdir -p src/features/my-feature/dto
# Create: create-my-feature.dto.ts, update-my-feature.dto.ts
```

### Standard Module Structure

```
modules/
├── my-feature/
│   ├── my-feature.module.ts
│   ├── controllers/
│   │   └── my-feature.controller.ts
│   ├── services/
│   │   └── my-feature.service.ts
│   ├── dto/
│   │   ├── create-my-feature.dto.ts
│   │   └── update-my-feature.dto.ts
│   ├── entities/
│   │   └── my-feature.entity.ts
│   └── repositories/
│       └── my-feature.repository.ts
```

## Related

- **Agents:** [backend-developer](../../agents/development/backend-developer.md)
- **Skills:** [run-fullstack](../../skills/dev/run-fullstack/SKILL.md)
