/// Framework templates are enabled only after Angular manifest detection.
Map<String, dynamic> angularSnippetsFor(String language) => switch (language) {
  'typescript' => _typescript,
  'html' => _html,
  _ => const {},
};

const _typescript = {
  "ngcomponent": {
    "prefix": "ngcomponent",
    "description": "Angular standalone component",
    "body":
        "import { Component } from '@angular/core';\n\n@Component({\n  selector: 'app-example',\n  standalone: true,\n  template: `<p>Example works!</p>`,\n})\nexport class ExampleComponent {\n  \n}",
  },
  "ngservice": {
    "prefix": "ngservice",
    "description": "Angular root service",
    "body":
        "import { Injectable } from '@angular/core';\n\n@Injectable({ providedIn: 'root' })\nexport class ExampleService {\n  \n}",
  },
  "nginject": {
    "prefix": "nginject",
    "description":
        "Angular dependency injection; import inject from @angular/core",
    "body": "private readonly service = inject(ExampleService);",
  },
  "ngsignal": {
    "prefix": "ngsignal",
    "description": "Angular signal; import signal from @angular/core",
    "body": "readonly count = signal(0);",
  },
  "ngcomputed": {
    "prefix": "ngcomputed",
    "description":
        "Angular computed signal; import computed from @angular/core",
    "body": "readonly doubled = computed(() => this.count() * 2);",
  },
  "nginput": {
    "prefix": "nginput",
    "description": "Angular signal input; import input from @angular/core",
    "body": "readonly name = input<string>();",
  },
  "nginit": {
    "prefix": "nginit",
    "description": "Angular initialization hook",
    "body": "ngOnInit(): void {\n  \n}",
  },
  "ngdestroy": {
    "prefix": "ngdestroy",
    "description": "Angular cleanup hook",
    "body": "ngOnDestroy(): void {\n  \n}",
  },
  "ngdirective": {
    "prefix": "ngdirective",
    "description": "Angular standalone directive",
    "body":
        "import { Directive } from '@angular/core';\n\n@Directive({ selector: '[appExample]', standalone: true })\nexport class ExampleDirective {\n  \n}",
  },
  "ngpipe": {
    "prefix": "ngpipe",
    "description": "Angular standalone pipe",
    "body":
        "import { Pipe, PipeTransform } from '@angular/core';\n\n@Pipe({ name: 'example', standalone: true })\nexport class ExamplePipe implements PipeTransform {\n  transform(value: string): string {\n    return value;\n  }\n}",
  },
};
const _html = {
  "ngif": {
    "prefix": "ngif",
    "description": "Angular built-in conditional block",
    "body": "@if (condition) {\n  <p>Content</p>\n}",
  },
  "ngfor": {
    "prefix": "ngfor",
    "description": "Angular built-in loop with tracking",
    "body":
        "@for (item of items; track item.id) {\n  <p>{{ item.name }}</p>\n}",
  },
  "ngswitch": {
    "prefix": "ngswitch",
    "description": "Angular built-in switch",
    "body": "@switch (value) {\n  @default { <p>Default</p> }\n}",
  },
  "ngbind": {
    "prefix": "ngbind",
    "description": "Angular property binding",
    "body": "<div [class.active]=\"isActive\"></div>",
  },
  "ngevent": {
    "prefix": "ngevent",
    "description": "Angular event binding",
    "body": "<button (click)=\"onClick()\">Click</button>",
  },
};
