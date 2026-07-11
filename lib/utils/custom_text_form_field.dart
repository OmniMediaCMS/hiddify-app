import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/utils/text_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class CustomTextFormField extends HookConsumerWidget {
  const CustomTextFormField({
    super.key,
    this.onChanged,
    this.validator,
    this.controller,
    this.inputFormatters,
    this.initialValue = '',
    this.suffixIcon,
    this.label,
    this.hint,
    this.keyboardType,
    this.minLines,
    this.maxLines,
    this.isDense = false,
    this.autoValidate = false,
    this.autoCorrect = false,
  });

  final ValueChanged<String>? onChanged;
  final String? Function(String? value)? validator;
  final TextEditingController? controller;
  final List<TextInputFormatter>? inputFormatters;
  final String initialValue;
  final Widget? suffixIcon;
  final String? label;
  final String? hint;
  final TextInputType? keyboardType;
  final int? minLines;
  final int? maxLines;
  final bool isDense;
  final bool autoValidate;
  final bool autoCorrect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textController = controller ?? useTextEditingController(text: initialValue);
    final effectiveConstraints = isDense ? const BoxConstraints(maxHeight: 56) : null;
    final effectiveBorder = isDense
        ? OutlineInputBorder(borderRadius: BorderRadius.circular(36), borderSide: BorderSide.none)
        : null;

    return TextFormField(
      controller: textController,
      textCapitalization: TextCapitalization.sentences,
      keyboardType: keyboardType,
      minLines: minLines,
      maxLines: maxLines,
      onChanged: onChanged,
      textDirection: textController.textDirection,
      decoration: InputDecoration(
        isDense: true,
        label: label != null ? Text(label!) : null,
        hintText: hint,
        hintStyle: Theme.of(context).textTheme.bodySmall,
        constraints: effectiveConstraints,
        suffixIcon: suffixIcon,
        border: effectiveBorder,
        enabledBorder: effectiveBorder,
        errorBorder: effectiveBorder,
        focusedBorder: effectiveBorder,
        focusedErrorBorder: effectiveBorder,
      ),
      validator: validator,
      textInputAction: keyboardType == TextInputType.multiline ? TextInputAction.newline : TextInputAction.next,
      inputFormatters: inputFormatters,
      autovalidateMode: autoValidate ? AutovalidateMode.always : AutovalidateMode.disabled,
      autocorrect: autoCorrect,
    );
  }
}
