use crate::cli_gen::gen_and_eval_llvm;
use crate::colors::{BLUE, END_COL, GREEN, PINK};
use bumpalo::Bump;
use const_format::concatcp;
use roc_collections::linked_list_extra::drain_filter;
use roc_collections::MutSet;
use roc_mono::ir::OptLevel;
use roc_parse::ast::{Expr, Pattern, TypeDef, ValueDef};
use roc_parse::expr::{parse_single_def, ExprParseOptions, SingleDef};
use roc_parse::parser::Either;
use roc_parse::parser::{EClosure, EExpr};
use roc_parse::state::State;
use roc_region::all::Loc;
use roc_repl_eval::gen::{Problems, ReplOutput};
use rustyline::highlight::{Highlighter, PromptInfo};
use rustyline::validate::{self, ValidationContext, ValidationResult, Validator};
use rustyline_derive::{Completer, Helper, Hinter};
use std::borrow::Cow;
use std::collections::LinkedList;
use target_lexicon::Triple;

pub const PROMPT: &str = concatcp!("\n", BLUE, "»", END_COL, " ");
pub const CONT_PROMPT: &str = concatcp!(BLUE, "…", END_COL, " ");

/// The prefix we use for the automatic variable names we assign to each expr,
/// e.g. if the prefix is "val" then the first expr you enter will be named "val1"
pub const AUTO_VAR_PREFIX: &str = "val";

// TODO add link to repl tutorial(does not yet exist).
pub const TIPS: &str = concatcp!(
    BLUE,
    "  - ",
    END_COL,
    PINK,
    "ctrl-v",
    END_COL,
    " + ",
    PINK,
    "ctrl-j",
    END_COL,
    " makes a newline\n\n",
    BLUE,
    "  - ",
    END_COL,
    ":q to quit\n\n",
    BLUE,
    "  - ",
    END_COL,
    ":help\n"
);

#[derive(Debug, Clone, PartialEq)]
struct PastDef {
    ident: String,
    src: String,
}

#[derive(Completer, Helper, Hinter)]
pub struct ReplState {
    validator: InputValidator,
    past_defs: LinkedList<PastDef>,
    past_def_idents: MutSet<String>,
    last_auto_ident: u64,
}

impl ReplState {
    pub fn new() -> Self {
        Self {
            validator: InputValidator::new(),
            past_defs: Default::default(),
            past_def_idents: Default::default(),
            last_auto_ident: 0,
        }
    }

    pub fn step(&mut self, line: &str) -> Result<String, i32> {
        let arena = Bump::new();

        match parse_src(&arena, line) {
            ParseOutcome::Empty => {
                if line.is_empty() {
                    return Ok(tips());
                } else if line.ends_with('\n') {
                    // After two blank lines in a row, give up and try parsing it
                    // even though it's going to fail. This way you don't get stuck
                    // in a perpetual Incomplete state due to a syntax error.
                    Ok(self.eval_and_format(line))
                } else {
                    // The previous line wasn't blank, but the line isn't empty either.
                    // This could mean that, for example, you're writing a multiline `when`
                    // and want to add a blank line. No problem! Print a blank line and
                    // continue waiting for input.
                    //
                    // If the user presses enter again, next time prev_line_blank() will be true
                    //  and we'll try parsing the source as-is.
                    Ok("\n".to_string())
                }
            }
            ParseOutcome::Expr(_)
            | ParseOutcome::ValueDef(_)
            | ParseOutcome::TypeDef(_)
            | ParseOutcome::Incomplete => Ok(self.eval_and_format(line)),
            ParseOutcome::Help => {
                // TODO add link to repl tutorial(does not yet exist).
                Ok(tips())
            }
            ParseOutcome::Exit => Err(0),
        }
    }

    pub fn eval_and_format<'a>(&mut self, src: &str) -> String {
        let arena = Bump::new();

        let src = match parse_src(&arena, src) {
            ParseOutcome::Expr(_) => src,
            ParseOutcome::ValueDef(value_def) => {
                match value_def {
                    ValueDef::Annotation(
                        Loc {
                            value: Pattern::Identifier(ident),
                            ..
                        },
                        _,
                    ) => {
                        // We received a type annotation, like `x : Str`
                        //
                        // This might be the beginning of an AnnotatedBody, or it might be
                        // a standalone annotation.
                        //
                        // If the input ends in a newline, that means the user pressed Enter
                        // twice after the annotation, indicating this is not an AnnotatedBody,
                        // but rather a standalone Annotation. As such, record it as a PastDef!
                        if src.ends_with('\n') {
                            // Record the standalone type annotation for future use
                            self.add_past_def(ident.trim_end().to_string(), src.to_string());
                        }

                        // Return early without running eval, since neither standalone annotations
                        // nor pending potential AnnotatedBody exprs can be evaluated as expressions.
                        return String::new();
                    }
                    ValueDef::Body(
                        Loc {
                            value: Pattern::Identifier(ident),
                            ..
                        },
                        _,
                    )
                    | ValueDef::AnnotatedBody {
                        body_pattern:
                            Loc {
                                value: Pattern::Identifier(ident),
                                ..
                            },
                        ..
                    } => {
                        self.add_past_def(ident.to_string(), src.to_string());

                        // Return early without running eval, since neither standalone annotations
                        // nor pending potential AnnotatedBody exprs can be evaluated as expressions.
                        return String::new();
                    }
                    ValueDef::Annotation(_, _)
                    | ValueDef::Body(_, _)
                    | ValueDef::AnnotatedBody { .. } => {
                        todo!("handle pattern other than identifier (which repl doesn't support)")
                    }
                    ValueDef::Expect { .. } => {
                        todo!("handle receiving an `expect` - what should the repl do for that?")
                    }
                    ValueDef::ExpectFx { .. } => {
                        todo!("handle receiving an `expect-fx` - what should the repl do for that?")
                    }
                }
            }
            ParseOutcome::TypeDef(_) => {
                // Alias, Opaque, or Ability
                todo!("handle Alias, Opaque, or Ability")
            }
            ParseOutcome::Incomplete => {
                if src.ends_with('\n') {
                    todo!("handle SYNTAX ERROR");
                } else {
                    todo!("handle Incomplete parse");
                }
            }
            ParseOutcome::Empty | ParseOutcome::Help | ParseOutcome::Exit => unreachable!(),
        };

        // Record e.g. "val1" as a past def, unless our input was exactly the name of
        // an existing identifer (e.g. I just typed "val1" into the prompt - there's no
        // need to reassign "val1" to "val2" just because I wanted to see what its value was!)
        let (output, problems) = match self.past_def_idents.get(src.trim()) {
            Some(existing_ident) => gen_and_eval_llvm(
                &self.with_past_defs(src),
                Triple::host(),
                OptLevel::Normal,
                existing_ident.to_string(),
            ),
            None => {
                let var_name = format!("{AUTO_VAR_PREFIX}{}", self.next_auto_ident());
                let answer = gen_and_eval_llvm(
                    &self.with_past_defs(src),
                    Triple::host(),
                    OptLevel::Normal,
                    var_name.clone(),
                );

                let src = format!("{var_name} = {}", src.trim_end());

                self.add_past_def(var_name, src);

                answer
            }
        };

        // TODO filter out UNUSED warnings for all past_def_ident entries
        // TODO allow turning off printing of warnings
        format_output(output, problems)
    }

    fn next_auto_ident(&mut self) -> u64 {
        self.last_auto_ident += 1;
        self.last_auto_ident
    }

    fn add_past_def(&mut self, ident: String, src: String) {
        let existing_idents = &mut self.past_def_idents;

        existing_idents.insert(ident.clone());

        // Override any defs that would be shadowed
        if !self.past_defs.is_empty() {
            drain_filter(&mut self.past_defs, |PastDef { ident, .. }| {
                if existing_idents.contains(ident) {
                    // We already have a newer def for this ident, so drop the old one.
                    false
                } else {
                    // We've never seen this def, so record it!
                    existing_idents.insert(ident.clone());

                    true
                }
            });
        }

        self.past_defs.push_front(PastDef { ident, src });
    }

    /// Wrap the given expresssion in the appropriate past defs
    pub fn with_past_defs(&self, src: &str) -> String {
        let mut buf = String::new();

        for past_def in self.past_defs.iter() {
            buf.push_str(past_def.src.as_str());
            buf.push('\n');
        }

        buf.push_str(src);

        buf
    }
}

#[derive(Debug, PartialEq)]
enum ParseOutcome<'a> {
    ValueDef(ValueDef<'a>),
    TypeDef(TypeDef<'a>),
    Expr(Expr<'a>),
    Incomplete,
    Empty,
    Help,
    Exit,
}

fn tips() -> String {
    format!("\n{}\n", TIPS)
}

fn parse_src<'a>(arena: &'a Bump, line: &'a str) -> ParseOutcome<'a> {
    match line.trim().to_lowercase().as_str() {
        "" => ParseOutcome::Empty,
        ":help" => ParseOutcome::Help,
        ":exit" | ":quit" | ":q" => ParseOutcome::Exit,
        _ => {
            let src_bytes = line.as_bytes();

            match roc_parse::expr::parse_loc_expr(0, &arena, State::new(src_bytes)) {
                Ok((_, loc_expr, _)) => ParseOutcome::Expr(loc_expr.value),
                // Special case some syntax errors to allow for multi-line inputs
                Err((_, EExpr::Closure(EClosure::Body(_, _), _), _)) => ParseOutcome::Incomplete,
                Err((_, EExpr::DefMissingFinalExpr(_), _))
                | Err((_, EExpr::DefMissingFinalExpr2(_, _), _)) => {
                    // This indicates that we had an attempted def; re-parse it as a single-line def.
                    match parse_single_def(
                        ExprParseOptions {
                            accept_multi_backpassing: true,
                            check_for_arrow: true,
                        },
                        0,
                        &arena,
                        State::new(src_bytes),
                    ) {
                        Ok((
                            _,
                            Some(SingleDef {
                                type_or_value: Either::First(type_def),
                                ..
                            }),
                            _,
                        )) => ParseOutcome::TypeDef(type_def),
                        Ok((
                            _,
                            Some(SingleDef {
                                type_or_value: Either::Second(value_def),
                                ..
                            }),
                            _,
                        )) => ParseOutcome::ValueDef(value_def),
                        Ok((_, None, _)) => {
                            todo!("TODO determine appropriate ParseOutcome for Ok(None)")
                        }
                        Err(_) => ParseOutcome::Incomplete,
                    }
                }
                Err(_) => ParseOutcome::Incomplete,
            }
        }
    }
}

struct InputValidator {}

impl InputValidator {
    pub fn new() -> InputValidator {
        InputValidator {}
    }
}

impl Validator for InputValidator {
    fn validate(&self, ctx: &mut ValidationContext) -> rustyline::Result<ValidationResult> {
        if is_incomplete(ctx.input()) {
            Ok(ValidationResult::Incomplete)
        } else {
            Ok(ValidationResult::Valid(None))
        }
    }
}

pub fn is_incomplete(input: &str) -> bool {
    let arena = Bump::new();

    match parse_src(&arena, input) {
        ParseOutcome::Incomplete => true,
        // Standalone annotations are default incomplete, because we can't know
        // whether they're about to annotate a body on the next line
        // (or if not, meaning they stay standalone) until you press Enter again!
        //
        // So it's Incomplete until you've pressed Enter again (causing the input to end in "\n")
        ParseOutcome::ValueDef(ValueDef::Annotation(_, _)) if !input.ends_with('\n') => true,
        ParseOutcome::Empty
        | ParseOutcome::Help
        | ParseOutcome::Exit
        | ParseOutcome::ValueDef(_)
        | ParseOutcome::TypeDef(_)
        | ParseOutcome::Expr(_) => false,
    }
}

impl Highlighter for ReplState {
    fn has_continuation_prompt(&self) -> bool {
        true
    }

    fn highlight_prompt<'b, 's: 'b, 'p: 'b>(
        &'s self,
        prompt: &'p str,
        info: PromptInfo<'_>,
    ) -> Cow<'b, str> {
        if info.line_no() > 0 {
            CONT_PROMPT.into()
        } else {
            prompt.into()
        }
    }
}

impl Validator for ReplState {
    fn validate(
        &self,
        ctx: &mut validate::ValidationContext,
    ) -> rustyline::Result<validate::ValidationResult> {
        self.validator.validate(ctx)
    }

    fn validate_while_typing(&self) -> bool {
        self.validator.validate_while_typing()
    }
}

fn format_output(opt_output: Option<ReplOutput>, problems: Problems) -> String {
    let mut buf = String::new();

    // Join all the warnings and errors together with blank lines.
    for message in problems.warnings.iter().chain(problems.errors.iter()) {
        if !buf.is_empty() {
            buf.push_str("\n\n");
        }

        buf.push('\n');
        buf.push_str(message);
        buf.push('\n');
    }

    if let Some(ReplOutput {
        expr,
        expr_type,
        var_name,
    }) = opt_output
    {
        // If expr was empty, it was a type annotation or ability declaration;
        // don't print anything!
        if !expr.is_empty() {
            buf.push_str(&format!(
                "\n{expr} {PINK}:{END_COL} {expr_type}  {GREEN} # {var_name}"
            ))
        }
    }

    buf
}
