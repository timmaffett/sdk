/*
 * Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
 * for details. All rights reserved. Use of this source code is governed by a
 * BSD-style license that can be found in the LICENSE file.
 *
 * This file has been automatically generated. Please do not edit it manually.
 * To regenerate the file, use the script "pkg/analysis_server/tool/spec/generate_files".
 */
package org.dartlang.analysis.server.protocol;

import java.util.Arrays;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.stream.Collectors;
import com.google.dart.server.utilities.general.JsonUtilities;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonPrimitive;

/**
 * A value of a property of a Flutter widget.
 *
 * @coverage dart.server.generated.types
 */
@SuppressWarnings("unused")
public class FlutterWidgetPropertyValue {

  public static final List<FlutterWidgetPropertyValue> EMPTY_LIST = List.of();

  private final Boolean boolValue;

  private final Double doubleValue;

  private final Integer intValue;

  private final String stringValue;

  private final FlutterWidgetPropertyValueEnumItem enumValue;

  /**
   * A free-form expression, which will be used as the value as is.
   */
  private final String expression;

  /**
   * Constructor for {@link FlutterWidgetPropertyValue}.
   */
  public FlutterWidgetPropertyValue(Boolean boolValue, Double doubleValue, Integer intValue, String stringValue, FlutterWidgetPropertyValueEnumItem enumValue, String expression) {
    this.boolValue = boolValue;
    this.doubleValue = doubleValue;
    this.intValue = intValue;
    this.stringValue = stringValue;
    this.enumValue = enumValue;
    this.expression = expression;
  }

  @Override
  public boolean equals(Object obj) {
    if (obj instanceof FlutterWidgetPropertyValue other) {
      return
        Objects.equals(other.boolValue, boolValue) &&
        Objects.equals(other.doubleValue, doubleValue) &&
        Objects.equals(other.intValue, intValue) &&
        Objects.equals(other.stringValue, stringValue) &&
        Objects.equals(other.enumValue, enumValue) &&
        Objects.equals(other.expression, expression);
    }
    return false;
  }

  public static FlutterWidgetPropertyValue fromJson(JsonObject jsonObject) {
    Boolean boolValue = jsonObject.get("boolValue") == null ? null : jsonObject.get("boolValue").getAsBoolean();
    Double doubleValue = jsonObject.get("doubleValue") == null ? null : jsonObject.get("doubleValue").getAsDouble();
    Integer intValue = jsonObject.get("intValue") == null ? null : jsonObject.get("intValue").getAsInt();
    String stringValue = jsonObject.get("stringValue") == null ? null : jsonObject.get("stringValue").getAsString();
    FlutterWidgetPropertyValueEnumItem enumValue = jsonObject.get("enumValue") == null ? null : FlutterWidgetPropertyValueEnumItem.fromJson(jsonObject.get("enumValue").getAsJsonObject());
    String expression = jsonObject.get("expression") == null ? null : jsonObject.get("expression").getAsString();
    return new FlutterWidgetPropertyValue(boolValue, doubleValue, intValue, stringValue, enumValue, expression);
  }

  public static List<FlutterWidgetPropertyValue> fromJsonArray(JsonArray jsonArray) {
    if (jsonArray == null) {
      return EMPTY_LIST;
    }
    List<FlutterWidgetPropertyValue> list = new ArrayList<>(jsonArray.size());
    for (final JsonElement element : jsonArray) {
      list.add(fromJson(element.getAsJsonObject()));
    }
    return list;
  }

  public Boolean getBoolValue() {
    return boolValue;
  }

  public Double getDoubleValue() {
    return doubleValue;
  }

  public FlutterWidgetPropertyValueEnumItem getEnumValue() {
    return enumValue;
  }

  /**
   * A free-form expression, which will be used as the value as is.
   */
  public String getExpression() {
    return expression;
  }

  public Integer getIntValue() {
    return intValue;
  }

  public String getStringValue() {
    return stringValue;
  }

  @Override
  public int hashCode() {
    return Objects.hash(
      boolValue,
      doubleValue,
      intValue,
      stringValue,
      enumValue,
      expression
    );
  }

  public JsonObject toJson() {
    JsonObject jsonObject = new JsonObject();
    if (boolValue != null) {
      jsonObject.addProperty("boolValue", boolValue);
    }
    if (doubleValue != null) {
      jsonObject.addProperty("doubleValue", doubleValue);
    }
    if (intValue != null) {
      jsonObject.addProperty("intValue", intValue);
    }
    if (stringValue != null) {
      jsonObject.addProperty("stringValue", stringValue);
    }
    if (enumValue != null) {
      jsonObject.add("enumValue", enumValue.toJson());
    }
    if (expression != null) {
      jsonObject.addProperty("expression", expression);
    }
    return jsonObject;
  }

  @Override
  public String toString() {
    StringBuilder builder = new StringBuilder();
    builder.append("[");
    builder.append("boolValue=");
    builder.append(boolValue);
    builder.append(", ");
    builder.append("doubleValue=");
    builder.append(doubleValue);
    builder.append(", ");
    builder.append("intValue=");
    builder.append(intValue);
    builder.append(", ");
    builder.append("stringValue=");
    builder.append(stringValue);
    builder.append(", ");
    builder.append("enumValue=");
    builder.append(enumValue);
    builder.append(", ");
    builder.append("expression=");
    builder.append(expression);
    builder.append("]");
    return builder.toString();
  }

}
