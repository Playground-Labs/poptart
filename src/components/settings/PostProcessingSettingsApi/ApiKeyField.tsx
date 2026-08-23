import React, { useState } from "react";
import { Input } from "../../ui/Input";

interface ApiKeyFieldProps {
  configured: boolean;
  onBlur: (value: string) => void;
  disabled: boolean;
  placeholder?: string;
  configuredPlaceholder?: string;
  className?: string;
}

export const ApiKeyField: React.FC<ApiKeyFieldProps> = React.memo(
  ({
    configured,
    onBlur,
    disabled,
    placeholder,
    configuredPlaceholder,
    className = "",
  }) => {
    const [localValue, setLocalValue] = useState("");
    const [dirty, setDirty] = useState(false);

    return (
      <Input
        type="password"
        value={localValue}
        onChange={(event) => {
          setLocalValue(event.target.value);
          setDirty(true);
        }}
        onBlur={() => {
          if (!dirty) return;
          onBlur(localValue);
          setLocalValue("");
          setDirty(false);
        }}
        placeholder={configured ? configuredPlaceholder : placeholder}
        variant="compact"
        disabled={disabled}
        className={`flex-1 min-w-[320px] ${className}`}
      />
    );
  },
);

ApiKeyField.displayName = "ApiKeyField";
