/// React templates are enabled only after manifest detection.
Map<String, dynamic> reactSnippetsFor(String language) =>
    language == 'typescript' || language == 'javascript' ? _react : const {};

const _react = {
  "rccomponent": {
    "prefix": "rccomponent",
    "description": "React function component (JSX/TSX)",
    "body":
        "export default function Example() {\n  return <div>Example</div>;\n}",
  },
  "rcstate": {
    "prefix": "rcstate",
    "description": "React state; import useState from react",
    "body": "const [count, setCount] = useState(0);",
  },
  "rceffect": {
    "prefix": "rceffect",
    "description": "React effect with cleanup; import useEffect from react",
    "body":
        "useEffect(() => {\n  // Set up synchronization here.\n  return () => {\n    // Clean up synchronization here.\n  };\n}, []);",
  },
  "rcref": {
    "prefix": "rcref",
    "description": "React ref; import useRef from react",
    "body": "const valueRef = useRef(null);",
  },
  "rcmemo": {
    "prefix": "rcmemo",
    "description": "React memoized value; import useMemo from react",
    "body": "const result = useMemo(() => computeValue(), []);",
  },
  "rccallback": {
    "prefix": "rccallback",
    "description": "React memoized callback; import useCallback from react",
    "body": "const handleClick = useCallback(() => {\n  \n}, []);",
  },
  "rccontext": {
    "prefix": "rccontext",
    "description": "React context; import createContext from react",
    "body": "const ExampleContext = createContext(null);",
  },
  "rcusecontext": {
    "prefix": "rcusecontext",
    "description": "React context reader; import useContext from react",
    "body": "const value = useContext(ExampleContext);",
  },
  "rclist": {
    "prefix": "rclist",
    "description": "React list with stable keys",
    "body": "{items.map(item => (\n  <div key={item.id}>{item.name}</div>\n))}",
  },
  "rcfragment": {
    "prefix": "rcfragment",
    "description": "React JSX fragment",
    "body": "<>\n  <div>Content</div>\n</>",
  },
};
