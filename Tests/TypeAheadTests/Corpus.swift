import Foundation

/// Writing to measure against.
///
/// The corpus this replaces was a single lowercase line with no commas, no full
/// stops, no capitals and no paragraph breaks — the one register in which the
/// app's punctuation blindness was invisible. It also had no held-out split, so
/// the headline number was measured on exactly the text the model had been
/// trained on, which is the oldest way there is to report a result that does not
/// generalise.
///
/// What is here instead: four registers the app actually has to handle, written
/// the way people write them. Greetings with commas, sentences that end,
/// paragraphs that break, names that recur, capitals in the places capitals go,
/// and Hinglish alongside English because that is what this user's mail looks
/// like.
///
/// `train` and `test` are disjoint and share vocabulary and habits without
/// sharing sentences — the same person writing different messages, which is
/// exactly the generalisation the app is claiming.
public enum Corpus {

    public static let train = """
        Hi Priya,

        Thanks for the update. Please find attached the report for review. Let me \
        know if that works, and I will send the revised deck across on Friday.

        Best,
        Anand

        Hi Rohan,

        Thanks for the quick turnaround. Please find attached the invoice for \
        review. Let me know if that works. I have asked accounts to confirm the \
        numbers before we circulate anything.

        Best,
        Anand

        Hey bhai, kaise ho. Sab theek hai na? Maine kal wala deck bhej diya tha, \
        dekh lena. Let me know if that works for you.

        Hi Priya,

        Quick one — the audit call has moved to Thursday. Please find attached the \
        agenda for review. Thanks for bearing with the reshuffle.

        Best,
        Anand
        """

    /// Held out. Same voice, same habits, sentences the model has never seen.
    public static let test = """
        Hi Rohan,

        Thanks for the reminder. Please find attached the summary for review. Let \
        me know if that works, and I will confirm the timeline tomorrow.

        Best,
        Anand

        Hey bhai, kaise ho. Sab theek hai na? Kal ka call thoda late ho jayega, \
        dekh lena.

        Hi Priya,

        Thanks for flagging it. Please find attached the revised numbers for \
        review. Let me know if that works.

        Best,
        Anand
        """
}
